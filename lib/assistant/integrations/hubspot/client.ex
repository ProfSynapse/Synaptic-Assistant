# lib/assistant/integrations/hubspot/client.ex — HubSpot CRM v3 API HTTP client.
#
# Provides functions for interacting with the HubSpot CRM v3 API via Req.
# Supports CRUD + search + list for Contacts, Companies, and Deals.
#
# Related files:
#   - lib/assistant/integration_settings/connection_validator.ex (health check consumer)
#   - lib/assistant/skills/hubspot/ (skill handlers consume CRUD methods)

defmodule Assistant.Integrations.HubSpot.Client do
  @moduledoc """
  HubSpot CRM v3 API HTTP client.

  Sends requests to the HubSpot API using `Req`. All methods accept the API key
  as their first parameter (Private App token, resolved by skill handlers via
  `IntegrationSettings.get(:hubspot_api_key)`).

  ## Object Types

  Three CRM object types are supported:
  - **Contacts** — email, firstname, lastname, phone, company
  - **Companies** — name, domain, website, industry, description
  - **Deals** — dealname, amount, closedate, dealstage, pipeline, description

  Each object type has six operations: create, get, update, delete, search, list_recent.

  ## Return Values

  All methods return tagged tuples:
  - `{:ok, map()}` — single object (create, get, update)
  - `{:ok, [map()]}` — list of objects (search, list_recent)
  - `:ok` — delete (archive) succeeded
  - `{:error, {:api_error, status, message}}` — HubSpot API error
  - `{:error, {:request_failed, reason}}` — network/connection failure

  ## Usage

      HubSpot.Client.health_check("pat-xxx")
      HubSpot.Client.create_contact("pat-xxx", %{"email" => "j@example.com"})
      HubSpot.Client.search_contacts("pat-xxx", "email", "EQ", "j@example.com", 10)
  """

  require Logger

  @default_base_url "https://api.hubapi.com"

  # Default properties requested from the API for each object type.
  @contact_properties ~w(email firstname lastname phone company)
  @company_properties ~w(name domain website industry description)
  @deal_properties ~w(dealname amount closedate dealstage pipeline description)

  # ---------------------------------------------------------------------------
  # Health Check
  # ---------------------------------------------------------------------------

  @doc """
  Verify HubSpot API connectivity with a lightweight contacts query.

  ## Parameters

    * `api_key` - The HubSpot private app token

  ## Returns

    * `{:ok, :healthy}` — API key is valid and API is reachable
    * `{:error, reason}` — API error or network failure
  """
  @spec health_check(String.t()) :: {:ok, :healthy} | {:error, term()}
  def health_check(api_key) do
    url = "#{base_url()}/crm/v3/objects/contacts"

    case Req.get(url,
           params: [limit: 1],
           headers: auth_headers(api_key),
           receive_timeout: 5_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200}} ->
        {:ok, :healthy}

      {:ok, %Req.Response{status: status, body: body}} ->
        message = extract_error_message(body)
        Logger.warning("HubSpot API error", status: status, message: message)
        {:error, {:api_error, status, message}}

      {:error, reason} ->
        Logger.error("HubSpot API request failed", reason: Exception.message(reason))
        {:error, {:request_failed, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Contacts
  # ---------------------------------------------------------------------------

  @spec create_contact(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_contact(api_key, properties), do: crm_create(api_key, "contacts", properties)

  @spec get_contact(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_contact(api_key, id), do: crm_get(api_key, "contacts", id, @contact_properties)

  @spec update_contact(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_contact(api_key, id, properties), do: crm_update(api_key, "contacts", id, properties)

  @spec delete_contact(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_contact(api_key, id), do: crm_delete(api_key, "contacts", id)

  @spec search_contacts(String.t(), String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def search_contacts(api_key, property, operator, value, limit) do
    crm_search(api_key, "contacts", property, operator, value, limit, @contact_properties)
  end

  @spec list_recent_contacts(String.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def list_recent_contacts(api_key, limit), do: crm_list(api_key, "contacts", limit, @contact_properties)

  # ---------------------------------------------------------------------------
  # Companies
  # ---------------------------------------------------------------------------

  @spec create_company(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_company(api_key, properties), do: crm_create(api_key, "companies", properties)

  @spec get_company(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_company(api_key, id), do: crm_get(api_key, "companies", id, @company_properties)

  @spec update_company(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_company(api_key, id, properties), do: crm_update(api_key, "companies", id, properties)

  @spec delete_company(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_company(api_key, id), do: crm_delete(api_key, "companies", id)

  @spec search_companies(String.t(), String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def search_companies(api_key, property, operator, value, limit) do
    crm_search(api_key, "companies", property, operator, value, limit, @company_properties)
  end

  @spec list_recent_companies(String.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def list_recent_companies(api_key, limit), do: crm_list(api_key, "companies", limit, @company_properties)

  # ---------------------------------------------------------------------------
  # Deals
  # ---------------------------------------------------------------------------

  @spec create_deal(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_deal(api_key, properties), do: crm_create(api_key, "deals", properties)

  @spec get_deal(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_deal(api_key, id), do: crm_get(api_key, "deals", id, @deal_properties)

  @spec update_deal(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_deal(api_key, id, properties), do: crm_update(api_key, "deals", id, properties)

  @spec delete_deal(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_deal(api_key, id), do: crm_delete(api_key, "deals", id)

  @spec search_deals(String.t(), String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def search_deals(api_key, property, operator, value, limit) do
    crm_search(api_key, "deals", property, operator, value, limit, @deal_properties)
  end

  @spec list_recent_deals(String.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def list_recent_deals(api_key, limit), do: crm_list(api_key, "deals", limit, @deal_properties)

  # ---------------------------------------------------------------------------
  # Generic CRM Operations (private)
  # ---------------------------------------------------------------------------

  defp crm_create(api_key, object_type, properties) do
    url = "#{base_url()}/crm/v3/objects/#{object_type}"

    case Req.post(url,
           json: %{properties: properties},
           headers: auth_headers(api_key),
           receive_timeout: 10_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 201, body: body}} ->
        {:ok, normalize_object(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, extract_error_message(body)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp crm_get(api_key, object_type, id, properties_list) do
    url = "#{base_url()}/crm/v3/objects/#{object_type}/#{id}"

    case Req.get(url,
           params: [properties: Enum.join(properties_list, ",")],
           headers: auth_headers(api_key),
           receive_timeout: 10_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, normalize_object(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, extract_error_message(body)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp crm_update(api_key, object_type, id, properties) do
    url = "#{base_url()}/crm/v3/objects/#{object_type}/#{id}"

    case Req.patch(url,
           json: %{properties: properties},
           headers: auth_headers(api_key),
           receive_timeout: 10_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, normalize_object(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, extract_error_message(body)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp crm_delete(api_key, object_type, id) do
    url = "#{base_url()}/crm/v3/objects/#{object_type}/#{id}"

    case Req.delete(url,
           headers: auth_headers(api_key),
           receive_timeout: 10_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 204}} ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, extract_error_message(body)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp crm_search(api_key, object_type, property, operator, value, limit, properties_list) do
    url = "#{base_url()}/crm/v3/objects/#{object_type}/search"

    case Req.post(url,
           json: build_search_body(property, operator, value, limit, properties_list),
           headers: auth_headers(api_key),
           receive_timeout: 10_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: %{"results" => results}}} ->
        {:ok, Enum.map(results, &normalize_object/1)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, extract_error_message(body)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp crm_list(api_key, object_type, limit, properties_list) do
    url = "#{base_url()}/crm/v3/objects/#{object_type}"

    case Req.get(url,
           params: [limit: limit, properties: Enum.join(properties_list, ",")],
           headers: auth_headers(api_key),
           receive_timeout: 10_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: %{"results" => results}}} ->
        {:ok, Enum.map(results, &normalize_object/1)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, extract_error_message(body)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp auth_headers(api_key), do: [{"authorization", "Bearer #{api_key}"}]

  defp base_url do
    Application.get_env(:assistant, :hubspot_api_base_url, @default_base_url)
  end

  defp normalize_object(body) when is_map(body) do
    %{
      id: body["id"],
      properties: body["properties"] || %{},
      created_at: body["createdAt"],
      updated_at: body["updatedAt"]
    }
  end

  defp build_search_body(property, operator, value, limit, properties_list) do
    %{
      filterGroups: [
        %{
          filters: [
            %{
              propertyName: property,
              operator: operator,
              value: value
            }
          ]
        }
      ],
      limit: limit,
      properties: properties_list
    }
  end

  defp extract_error_message(%{"message" => message}), do: message
  defp extract_error_message(body) when is_map(body), do: inspect(body)
  defp extract_error_message(body), do: to_string(body)
end

# lib/assistant/integrations/hubspot/client.ex — HubSpot CRM v3 API HTTP client.
#
# Provides functions for interacting with the HubSpot CRM v3 API via Req.
# Supports CRUD + search + list for Contacts, Companies, and Deals.
# Includes retry with backoff for transient errors (429/5xx) and
# cursor-based pagination for list operations.
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
  - `{:ok, %{results: [map()], next: cursor | nil}}` — paginated list (search, list_recent)
  - `:ok` — delete (archive) succeeded
  - `{:error, {:api_error, status, message}}` — HubSpot API error
  - `{:error, {:request_failed, reason}}` — network/connection failure

  ## Retry

  All CRM operations (except `health_check`) retry on transient errors
  (408, 429, 5xx) up to 3 times with linear backoff (500ms * attempt).

  ## Usage

      HubSpot.Client.health_check("pat-xxx")
      HubSpot.Client.create_contact("pat-xxx", %{"email" => "j@example.com"})
      HubSpot.Client.search_contacts("pat-xxx", "email", "EQ", "j@example.com", 10)
      HubSpot.Client.list_recent_contacts("pat-xxx", 10, "cursor123")
  """

  require Logger

  @default_base_url "https://api.hubapi.com"
  @max_retries 3

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
    crm_search(api_key, "contacts", [{property, operator, value}], limit, @contact_properties)
  end

  @spec list_recent_contacts(String.t(), pos_integer(), String.t() | nil) ::
          {:ok, %{results: [map()], next: String.t() | nil}} | {:error, term()}
  def list_recent_contacts(api_key, limit, after_cursor \\ nil) do
    crm_list(api_key, "contacts", limit, @contact_properties, after_cursor)
  end

  # ---------------------------------------------------------------------------
  # Companies
  # ---------------------------------------------------------------------------

  @spec create_company(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_company(api_key, properties), do: crm_create(api_key, "companies", properties)

  @spec get_company(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_company(api_key, id), do: crm_get(api_key, "companies", id, @company_properties)

  @spec update_company(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_company(api_key, id, properties),
    do: crm_update(api_key, "companies", id, properties)

  @spec delete_company(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_company(api_key, id), do: crm_delete(api_key, "companies", id)

  @spec search_companies(String.t(), String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def search_companies(api_key, property, operator, value, limit) do
    crm_search(api_key, "companies", [{property, operator, value}], limit, @company_properties)
  end

  @spec list_recent_companies(String.t(), pos_integer(), String.t() | nil) ::
          {:ok, %{results: [map()], next: String.t() | nil}} | {:error, term()}
  def list_recent_companies(api_key, limit, after_cursor \\ nil) do
    crm_list(api_key, "companies", limit, @company_properties, after_cursor)
  end

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
    crm_search(api_key, "deals", [{property, operator, value}], limit, @deal_properties)
  end

  @spec list_recent_deals(String.t(), pos_integer(), String.t() | nil) ::
          {:ok, %{results: [map()], next: String.t() | nil}} | {:error, term()}
  def list_recent_deals(api_key, limit, after_cursor \\ nil) do
    crm_list(api_key, "deals", limit, @deal_properties, after_cursor)
  end

  # ---------------------------------------------------------------------------
  # Multi-filter search (advanced)
  # ---------------------------------------------------------------------------

  @doc """
  Search CRM objects with multiple filters (AND logic within a single filter group).

  Accepts a list of `{property, operator, value}` filter tuples.

  ## Parameters

    * `api_key` - HubSpot private app token
    * `object_type` - "contacts", "companies", or "deals"
    * `filters` - list of `{property, operator, value}` tuples
    * `limit` - max results
    * `properties_list` - properties to return

  ## Returns

    * `{:ok, [map()]}` — list of matching objects
    * `{:error, reason}` — API or network error
  """
  @spec crm_search_multi(
          String.t(),
          String.t(),
          [{String.t(), String.t(), String.t()}],
          pos_integer(),
          [String.t()]
        ) ::
          {:ok, [map()]} | {:error, term()}
  def crm_search_multi(api_key, object_type, filters, limit, properties_list) do
    crm_search(api_key, object_type, filters, limit, properties_list)
  end

  # ---------------------------------------------------------------------------
  # Generic CRM Operations (private)
  # ---------------------------------------------------------------------------

  defp crm_create(api_key, object_type, properties) do
    url = "#{base_url()}/crm/v3/objects/#{object_type}"

    case Req.post(url,
           json: %{properties: properties},
           headers: auth_headers(api_key),
           receive_timeout: 10_000,
           retry: :transient,
           retry_delay: &retry_delay/1,
           max_retries: @max_retries
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
           retry: :transient,
           retry_delay: &retry_delay/1,
           max_retries: @max_retries
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
           retry: :transient,
           retry_delay: &retry_delay/1,
           max_retries: @max_retries
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
           retry: :transient,
           retry_delay: &retry_delay/1,
           max_retries: @max_retries
         ) do
      {:ok, %Req.Response{status: 204}} ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, extract_error_message(body)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp crm_search(api_key, object_type, filters, limit, properties_list) when is_list(filters) do
    url = "#{base_url()}/crm/v3/objects/#{object_type}/search"

    case Req.post(url,
           json: build_search_body(filters, limit, properties_list),
           headers: auth_headers(api_key),
           receive_timeout: 10_000,
           retry: :transient,
           retry_delay: &retry_delay/1,
           max_retries: @max_retries
         ) do
      {:ok, %Req.Response{status: 200, body: %{"results" => results}}} ->
        {:ok, Enum.map(results, &normalize_object/1)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, extract_error_message(body)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp crm_list(api_key, object_type, limit, properties_list, after_cursor) do
    url = "#{base_url()}/crm/v3/objects/#{object_type}"

    params =
      [limit: limit, properties: Enum.join(properties_list, ",")]
      |> maybe_add_after(after_cursor)

    case Req.get(url,
           params: params,
           headers: auth_headers(api_key),
           receive_timeout: 10_000,
           retry: :transient,
           retry_delay: &retry_delay/1,
           max_retries: @max_retries
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        results = Map.get(body, "results", [])
        next_cursor = get_in(body, ["paging", "next", "after"])

        {:ok, %{results: Enum.map(results, &normalize_object/1), next: next_cursor}}

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

  defp retry_delay(n), do: 500 * n

  defp maybe_add_after(params, nil), do: params
  defp maybe_add_after(params, ""), do: params
  defp maybe_add_after(params, cursor), do: Keyword.put(params, :after, cursor)

  defp normalize_object(body) when is_map(body) do
    %{
      id: body["id"],
      properties: body["properties"] || %{},
      created_at: body["createdAt"],
      updated_at: body["updatedAt"]
    }
  end

  defp build_search_body(filters, limit, properties_list) when is_list(filters) do
    filter_maps =
      Enum.map(filters, fn {property, operator, value} ->
        %{
          propertyName: property,
          operator: operator,
          value: value
        }
      end)

    %{
      filterGroups: [%{filters: filter_maps}],
      limit: limit,
      properties: properties_list
    }
  end

  defp extract_error_message(%{"message" => message}), do: message
  defp extract_error_message(body) when is_map(body), do: inspect(body)
  defp extract_error_message(body), do: to_string(body)
end

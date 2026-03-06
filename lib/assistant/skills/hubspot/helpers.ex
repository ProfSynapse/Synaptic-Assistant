# lib/assistant/skills/hubspot/helpers.ex — HubSpot-domain helpers shared by all HubSpot skill handlers.
#
# Provides formatting and utility functions for CRM object display, limit
# parsing, and optional-field map building. Each HubSpot object family
# (contacts, companies, deals) uses these helpers for consistent output.
#
# Related files:
#   - lib/assistant/skills/helpers.ex (cross-domain parse_limit)
#   - lib/assistant/skills/hubspot/contacts/*.ex (contact skill handlers)
#   - lib/assistant/skills/hubspot/companies/*.ex (company skill handlers)
#   - lib/assistant/skills/hubspot/deals/*.ex (deal skill handlers)

defmodule Assistant.Skills.HubSpot.Helpers do
  @moduledoc false

  alias Assistant.Skills.Helpers, as: SkillsHelpers

  @default_limit 10
  @max_limit 50

  @doc """
  Returns the display field tuples for contacts: `[{label, property_name}]`.
  """
  def contact_fields do
    [
      {"Email", "email"},
      {"First Name", "firstname"},
      {"Last Name", "lastname"},
      {"Phone", "phone"},
      {"Company", "company"}
    ]
  end

  @doc """
  Returns the display field tuples for companies: `[{label, property_name}]`.
  """
  def company_fields do
    [
      {"Name", "name"},
      {"Domain", "domain"},
      {"Website", "website"},
      {"Industry", "industry"},
      {"Description", "description"}
    ]
  end

  @doc """
  Returns the display field tuples for deals: `[{label, property_name}]`.
  """
  def deal_fields do
    [
      {"Deal Name", "dealname"},
      {"Amount", "amount"},
      {"Close Date", "closedate"},
      {"Stage", "dealstage"},
      {"Pipeline", "pipeline"},
      {"Description", "description"}
    ]
  end

  @doc """
  Parses a limit value, clamped between 1 and 50, defaulting to 10.
  """
  def parse_limit(value), do: SkillsHelpers.parse_limit(value, @default_limit, @max_limit)

  @doc """
  Puts a key-value pair into the map only when value is non-nil and non-empty.
  """
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, _key, ""), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Formats a single CRM object into a human-readable text block.

  Prepends the object ID, then lists each field from the `fields` list
  that has a non-nil value in the object's properties.

  ## Parameters

    * `object` - Map with `:id` and `:properties` (or string keys)
    * `fields` - List of `{label, property_name}` tuples
  """
  def format_object(object, fields) do
    fields
    |> Enum.map(fn {label, key} ->
      value = get_in(object, [:properties, key]) || get_in(object, ["properties", key])
      if value, do: "#{label}: #{value}", else: nil
    end)
    |> Enum.reject(&is_nil/1)
    |> then(fn lines ->
      id = object[:id] || object["id"]
      ["ID: #{id}" | lines]
    end)
    |> Enum.join("\n")
  end

  @doc """
  Formats a list of CRM objects separated by dividers.

  Returns a "No {type} found." message for empty lists, or a count header
  followed by formatted objects separated by `---`.

  ## Parameters

    * `objects` - List of CRM object maps
    * `fields` - List of `{label, property_name}` tuples
    * `object_type_label` - Human label like "contacts" or "companies"
  """
  def format_object_list(objects, fields, object_type_label) do
    case objects do
      [] ->
        "No #{object_type_label} found."

      list ->
        formatted = Enum.map_join(list, "\n\n---\n\n", &format_object(&1, fields))
        "Found #{length(list)} #{object_type_label}:\n\n#{formatted}"
    end
  end

  @doc """
  Appends a pagination hint when a next cursor is present.
  """
  def maybe_append_pagination(formatted, nil), do: formatted
  def maybe_append_pagination(formatted, ""), do: formatted

  def maybe_append_pagination(formatted, cursor) do
    formatted <> "\n\nMore results available. Use --after #{cursor} to see the next page."
  end

  @doc """
  Parses a JSON string of filters into a list of `{property, operator, value}` tuples.

  Expects a JSON array of objects, each with "property", "operator", and "value" keys.

  ## Examples

      parse_filters_json(~s([{"property":"email","operator":"EQ","value":"j@example.com"}]))
      # => {:ok, [{"email", "EQ", "j@example.com"}]}
  """
  def parse_filters_json(nil), do: {:error, "Missing --filters value."}
  def parse_filters_json(""), do: {:error, "Missing --filters value."}

  def parse_filters_json(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, list} when is_list(list) ->
        filters =
          Enum.map(list, fn item ->
            {item["property"], item["operator"], item["value"]}
          end)

        if Enum.any?(filters, fn {p, o, v} -> is_nil(p) or is_nil(o) or is_nil(v) end) do
          {:error,
           "Each filter must have \"property\", \"operator\", and \"value\" keys. " <>
             "Example: [{\"property\":\"email\",\"operator\":\"EQ\",\"value\":\"j@example.com\"}]"}
        else
          {:ok, filters}
        end

      {:ok, _} ->
        {:error,
         "The --filters flag must be a JSON array. " <>
           "Example: [{\"property\":\"email\",\"operator\":\"EQ\",\"value\":\"j@example.com\"}]"}

      {:error, _} ->
        {:error, "Invalid JSON in --filters flag."}
    end
  end

  @doc """
  Parses a JSON string into a map of additional properties.

  Returns `{:ok, map}` on success or `{:error, message}` on invalid JSON.
  Returns `{:ok, %{}}` for nil input.
  """
  def parse_properties_json(nil), do: {:ok, %{}}
  def parse_properties_json(""), do: {:ok, %{}}

  def parse_properties_json(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _} ->
        {:error, "The --properties flag must be a JSON object (e.g. '{\"jobtitle\": \"CTO\"}')."}

      {:error, _} ->
        {:error,
         "Invalid JSON in --properties flag. Use valid JSON (e.g. '{\"jobtitle\": \"CTO\"}')."}
    end
  end

  @doc """
  Resolves the HubSpot API key from IntegrationSettings.
  """
  def resolve_api_key do
    Assistant.IntegrationSettings.get(:hubspot_api_key)
  end

  @doc """
  Standard error result for missing HubSpot integration.
  """
  def integration_not_configured do
    {:ok,
     %Assistant.Skills.Result{status: :error, content: "HubSpot integration not configured."}}
  end

  @doc """
  Standard error result for missing API key.
  """
  def api_key_not_found do
    {:ok,
     %Assistant.Skills.Result{
       status: :error,
       content: "HubSpot API key not found. Configure it in Settings."
     }}
  end

  @doc """
  Translates a HubSpot client error tuple into a Result.

  Handles common HTTP status codes with user-friendly messages.
  The /1 arity handles errors without object context; the /3 arity
  handles errors that reference a specific object type and identifier.
  """
  def handle_error({:error, {:api_error, 401, _}}) do
    {:ok,
     %Assistant.Skills.Result{
       status: :error,
       content: "HubSpot API key is invalid. Check Settings."
     }}
  end

  def handle_error({:error, {:api_error, 429, _}}) do
    {:ok,
     %Assistant.Skills.Result{
       status: :error,
       content: "HubSpot rate limit exceeded. Try again shortly."
     }}
  end

  def handle_error({:error, {:api_error, _status, message}}) do
    {:ok, %Assistant.Skills.Result{status: :error, content: "HubSpot API error: #{message}"}}
  end

  def handle_error({:error, {:request_failed, reason}}) do
    msg =
      if is_exception(reason),
        do: Exception.message(reason),
        else: inspect(reason)

    {:ok, %Assistant.Skills.Result{status: :error, content: "Failed to reach HubSpot: #{msg}"}}
  end

  def handle_error({:error, {:api_error, 404, _}}, object_type, id) do
    {:ok,
     %Assistant.Skills.Result{
       status: :error,
       content: "No #{object_type} found with ID #{id}."
     }}
  end

  def handle_error({:error, {:api_error, 409, _}}, object_type, field) do
    {:ok,
     %Assistant.Skills.Result{
       status: :error,
       content: "A #{object_type} with this #{field} already exists."
     }}
  end
end

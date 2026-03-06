# lib/assistant/skills/hubspot/contacts/search.ex — Handler for hubspot.search_contacts skill.
#
# Searches HubSpot contacts by email (EQ) or name (CONTAINS_TOKEN). Returns
# a formatted list of matching contacts capped by the --limit flag.
# Supports advanced multi-filter search via the --filters flag.
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (API client)
#   - lib/assistant/skills/hubspot/helpers.ex (shared helpers)
#   - priv/skills/hubspot/search_contacts.md (skill definition)

defmodule Assistant.Skills.HubSpot.Contacts.Search do
  @moduledoc false
  @behaviour Assistant.Skills.Handler

  alias Assistant.Integrations.HubSpot.Client
  alias Assistant.Skills.HubSpot.Helpers
  alias Assistant.Skills.Result

  @impl true
  def execute(flags, context) do
    case Map.get(context.integrations, :hubspot) do
      nil ->
        Helpers.integration_not_configured()

      hubspot ->
        case Helpers.resolve_api_key() do
          nil -> Helpers.api_key_not_found()
          api_key -> do_execute(hubspot, api_key, flags)
        end
    end
  end

  defp do_execute(hubspot, api_key, flags) do
    filters_json = Map.get(flags, "filters")

    if filters_json do
      execute_multi_filter(api_key, flags, filters_json)
    else
      execute_simple(hubspot, api_key, flags)
    end
  end

  defp execute_simple(hubspot, api_key, flags) do
    query = Map.get(flags, "query")

    if is_nil(query) || query == "" do
      {:ok, %Result{status: :error, content: "Missing required parameter: --query."}}
    else
      search_by = Map.get(flags, "search_by", "email")
      limit = Helpers.parse_limit(Map.get(flags, "limit"))

      case resolve_search_params(search_by) do
        {:ok, property, operator} ->
          case hubspot.search_contacts(api_key, property, operator, query, limit) do
            {:ok, contacts} ->
              formatted =
                Helpers.format_object_list(contacts, Helpers.contact_fields(), "contacts")

              {:ok, %Result{status: :ok, content: formatted}}

            error ->
              Helpers.handle_error(error)
          end

        {:error, message} ->
          {:ok, %Result{status: :error, content: message}}
      end
    end
  end

  defp execute_multi_filter(api_key, flags, filters_json) do
    limit = Helpers.parse_limit(Map.get(flags, "limit"))

    case Helpers.parse_filters_json(filters_json) do
      {:ok, filters} ->
        case Client.crm_search_multi(
               api_key,
               "contacts",
               filters,
               limit,
               ~w(email firstname lastname phone company)
             ) do
          {:ok, contacts} ->
            formatted = Helpers.format_object_list(contacts, Helpers.contact_fields(), "contacts")
            {:ok, %Result{status: :ok, content: formatted}}

          error ->
            Helpers.handle_error(error)
        end

      {:error, message} ->
        {:ok, %Result{status: :error, content: message}}
    end
  end

  defp resolve_search_params("email"), do: {:ok, "email", "EQ"}
  defp resolve_search_params("name"), do: {:ok, "firstname", "CONTAINS_TOKEN"}

  defp resolve_search_params(other) do
    {:error, "Invalid --search_by value: \"#{other}\". Must be \"email\" or \"name\"."}
  end
end

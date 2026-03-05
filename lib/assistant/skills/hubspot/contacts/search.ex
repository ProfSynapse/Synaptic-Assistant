# lib/assistant/skills/hubspot/contacts/search.ex — Handler for hubspot.search_contacts skill.
#
# Searches HubSpot contacts by email (EQ) or name (CONTAINS_TOKEN). Returns
# a formatted list of matching contacts capped by the --limit flag.
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (API client)
#   - lib/assistant/skills/hubspot/helpers.ex (shared helpers)
#   - priv/skills/hubspot/search_contacts.md (skill definition)

defmodule Assistant.Skills.HubSpot.Contacts.Search do
  @behaviour Assistant.Skills.Handler

  alias Assistant.Skills.HubSpot.Helpers
  alias Assistant.Skills.Result

  @contact_fields [
    {"Email", "email"},
    {"First Name", "firstname"},
    {"Last Name", "lastname"},
    {"Phone", "phone"},
    {"Company", "company"}
  ]

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
    query = Map.get(flags, "query")

    if is_nil(query) || query == "" do
      {:ok, %Result{status: :error, content: "Missing required parameter: --query."}}
    else
      search_by = Map.get(flags, "search_by", "email")
      limit = Helpers.parse_limit(Map.get(flags, "limit"))

      {property, operator} = resolve_search_params(search_by)

      case hubspot.search_contacts(api_key, property, operator, query, limit) do
        {:ok, contacts} ->
          formatted = Helpers.format_object_list(contacts, @contact_fields, "contacts")
          {:ok, %Result{status: :ok, content: formatted}}

        {:error, {:api_error, 401, _}} = error ->
          Helpers.handle_error(error)

        {:error, {:api_error, 429, _}} = error ->
          Helpers.handle_error(error)

        error ->
          Helpers.handle_error(error)
      end
    end
  end

  defp resolve_search_params("name"), do: {"firstname", "CONTAINS_TOKEN"}
  defp resolve_search_params(_email), do: {"email", "EQ"}
end

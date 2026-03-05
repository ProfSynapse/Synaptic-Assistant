# lib/assistant/skills/hubspot/contacts/list_recent.ex — Handler for hubspot.list_recent_contacts skill.
#
# Lists recently created or updated contacts from HubSpot CRM. Returns up to
# --limit contacts (default 10, max 50) with standard contact display fields.
# Supports cursor-based pagination via --after parameter.
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (API client)
#   - lib/assistant/skills/hubspot/helpers.ex (shared helpers)
#   - priv/skills/hubspot/list_recent_contacts.md (skill definition)

defmodule Assistant.Skills.HubSpot.Contacts.ListRecent do
  @moduledoc false
  @behaviour Assistant.Skills.Handler

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
    limit = Helpers.parse_limit(Map.get(flags, "limit"))
    after_cursor = Map.get(flags, "after")

    case hubspot.list_recent_contacts(api_key, limit, after_cursor) do
      {:ok, %{results: contacts, next: next}} ->
        formatted = Helpers.format_object_list(contacts, Helpers.contact_fields(), "contacts")
        content = Helpers.maybe_append_pagination(formatted, next)
        {:ok, %Result{status: :ok, content: content}}

      error ->
        Helpers.handle_error(error)
    end
  end
end

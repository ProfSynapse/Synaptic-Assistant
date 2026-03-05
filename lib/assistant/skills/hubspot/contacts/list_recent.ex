# lib/assistant/skills/hubspot/contacts/list_recent.ex — Handler for hubspot.list_recent_contacts skill.
#
# Lists recently created or updated contacts from HubSpot CRM. Returns up to
# --limit contacts (default 10, max 50) with standard contact display fields.
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (API client)
#   - lib/assistant/skills/hubspot/helpers.ex (shared helpers)
#   - priv/skills/hubspot/list_recent_contacts.md (skill definition)

defmodule Assistant.Skills.HubSpot.Contacts.ListRecent do
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
    limit = Helpers.parse_limit(Map.get(flags, "limit"))

    case hubspot.list_recent_contacts(api_key, limit) do
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

# lib/assistant/skills/hubspot/contacts/delete.ex — Handler for hubspot.delete_contact skill.
#
# Archives (deletes) a contact in HubSpot CRM by ID. HubSpot uses soft
# deletion — archived contacts can be restored from the HubSpot UI.
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (API client)
#   - lib/assistant/skills/hubspot/helpers.ex (shared helpers)
#   - priv/skills/hubspot/delete_contact.md (skill definition)

defmodule Assistant.Skills.HubSpot.Contacts.Delete do
  @behaviour Assistant.Skills.Handler

  require Logger

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
    id = Map.get(flags, "id")

    if is_nil(id) || id == "" do
      {:ok, %Result{status: :error, content: "Missing required parameter: --id."}}
    else
      case hubspot.delete_contact(api_key, id) do
        :ok ->
          Logger.info("HubSpot contact archived", contact_id: id)

          {:ok,
           %Result{
             status: :ok,
             content: "Contact #{id} has been archived successfully.\n\nNote: Archived contacts can be restored from the HubSpot UI.",
             side_effects: [:hubspot_contact_deleted],
             metadata: %{contact_id: id}
           }}

        {:error, {:api_error, 404, _}} = error ->
          Helpers.handle_error(error, "contact", id)

        {:error, {:api_error, 401, _}} = error ->
          Helpers.handle_error(error)

        {:error, {:api_error, 429, _}} = error ->
          Helpers.handle_error(error)

        error ->
          Helpers.handle_error(error)
      end
    end
  end
end

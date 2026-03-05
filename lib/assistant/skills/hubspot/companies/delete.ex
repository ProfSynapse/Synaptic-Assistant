# lib/assistant/skills/hubspot/companies/delete.ex — Handler for hubspot.delete_company skill.
#
# Archives (soft-deletes) a company in HubSpot CRM by ID. HubSpot's delete
# endpoint actually archives the record; it can be restored from the HubSpot UI.
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (HubSpot API client)
#   - lib/assistant/skills/hubspot/helpers.ex (shared HubSpot helpers)
#   - priv/skills/hubspot/delete_company.md (skill definition)

defmodule Assistant.Skills.HubSpot.Companies.Delete do
  @moduledoc false
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

    cond do
      is_nil(id) || id == "" ->
        {:ok, %Result{status: :error, content: "Missing required parameter: --id (company ID)."}}

      not String.match?(id, ~r/^\d+$/) ->
        {:ok, %Result{status: :error, content: "Invalid --id: must be a numeric HubSpot ID."}}

      true ->
        case hubspot.delete_company(api_key, id) do
          :ok ->
            Logger.info("HubSpot company archived", company_id: id)

            {:ok,
             %Result{
               status: :ok,
               content: "Company #{id} has been archived successfully.\n\nNote: Archived companies can be restored from the HubSpot UI.",
               side_effects: [:hubspot_company_deleted],
               metadata: %{company_id: id}
             }}

          {:error, {:api_error, 404, _}} = error ->
            Helpers.handle_error(error, "company", id)

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

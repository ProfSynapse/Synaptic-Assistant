# lib/assistant/skills/hubspot/companies/delete.ex — Handler for hubspot.delete_company skill.
#
# Archives (soft-deletes) a company in HubSpot CRM by ID. HubSpot's delete
# endpoint actually archives the record; it can be restored from the HubSpot UI.
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (HubSpot API client)
#   - priv/skills/hubspot/delete_company.md (skill definition)

defmodule Assistant.Skills.HubSpot.Companies.Delete do
  @behaviour Assistant.Skills.Handler

  require Logger

  alias Assistant.Skills.Result

  @impl true
  def execute(flags, context) do
    case Map.get(context.integrations, :hubspot) do
      nil ->
        {:ok, %Result{status: :error, content: "HubSpot integration not configured."}}

      hubspot ->
        case resolve_api_key() do
          nil ->
            {:ok, %Result{status: :error, content: "HubSpot API key not found. Configure it in Settings."}}

          api_key ->
            do_execute(hubspot, api_key, flags)
        end
    end
  end

  defp resolve_api_key do
    Assistant.IntegrationSettings.get(:hubspot_api_key)
  end

  defp do_execute(hubspot, api_key, flags) do
    id = Map.get(flags, "id")

    if is_nil(id) || id == "" do
      {:ok, %Result{status: :error, content: "Missing required parameter: --id (company ID)."}}
    else
      case hubspot.delete_company(api_key, id) do
        :ok ->
          Logger.info("HubSpot company archived", company_id: id)

          {:ok,
           %Result{
             status: :ok,
             content: "Company #{id} has been archived. It can be restored from the HubSpot recycling bin.",
             side_effects: [:hubspot_company_deleted],
             metadata: %{company_id: id}
           }}

        {:error, {:api_error, 404, _}} ->
          {:ok, %Result{status: :error, content: "No company found with ID #{id}."}}

        {:error, {:api_error, 401, _}} ->
          {:ok, %Result{status: :error, content: "HubSpot API key is invalid. Check Settings."}}

        {:error, {:api_error, 429, _}} ->
          {:ok, %Result{status: :error, content: "HubSpot rate limit exceeded. Try again shortly."}}

        {:error, {:api_error, _status, message}} ->
          {:ok, %Result{status: :error, content: "HubSpot API error: #{message}"}}

        {:error, {:request_failed, reason}} ->
          {:ok, %Result{status: :error, content: "Failed to reach HubSpot: #{Exception.message(reason)}"}}
      end
    end
  end
end

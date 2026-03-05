# lib/assistant/skills/hubspot/deals/delete.ex — Handler for hubspot.delete_deal skill.
#
# Archives (soft-deletes) a deal in HubSpot CRM by ID. HubSpot's delete
# endpoint actually archives the record rather than permanently removing it.
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (HubSpot API client)
#   - priv/skills/hubspot/delete_deal.md (skill definition)

defmodule Assistant.Skills.HubSpot.Deals.Delete do
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

  defp resolve_api_key, do: Assistant.IntegrationSettings.get(:hubspot_api_key)

  defp do_execute(hubspot, api_key, flags) do
    id = Map.get(flags, "id")

    if is_nil(id) || id == "" do
      {:ok, %Result{status: :error, content: "Missing required parameter: --id (deal ID)."}}
    else
      delete_deal(hubspot, api_key, id)
    end
  end

  defp delete_deal(hubspot, api_key, id) do
    case hubspot.delete_deal(api_key, id) do
      :ok ->
        Logger.info("HubSpot deal archived", deal_id: id)

        {:ok,
         %Result{
           status: :ok,
           content: "Deal #{id} has been archived successfully.",
           side_effects: [:hubspot_deal_deleted],
           metadata: %{deal_id: id}
         }}

      {:error, {:api_error, 404, _}} ->
        {:ok, %Result{status: :error, content: "No deal found with ID #{id}."}}

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

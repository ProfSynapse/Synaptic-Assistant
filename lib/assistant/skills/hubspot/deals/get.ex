# lib/assistant/skills/hubspot/deals/get.ex — Handler for hubspot.get_deal skill.
#
# Retrieves a single deal from HubSpot CRM by ID and formats the result.
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (HubSpot API client)
#   - lib/assistant/skills/hubspot/helpers.ex (shared HubSpot helpers)
#   - priv/skills/hubspot/get_deal.md (skill definition)

defmodule Assistant.Skills.HubSpot.Deals.Get do
  @behaviour Assistant.Skills.Handler

  alias Assistant.Skills.HubSpot.Helpers
  alias Assistant.Skills.Result

  @deal_fields [
    {"Deal Name", "dealname"},
    {"Amount", "amount"},
    {"Close Date", "closedate"},
    {"Stage", "dealstage"},
    {"Pipeline", "pipeline"},
    {"Description", "description"}
  ]

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
      get_deal(hubspot, api_key, id)
    end
  end

  defp get_deal(hubspot, api_key, id) do
    case hubspot.get_deal(api_key, id) do
      {:ok, deal} ->
        formatted = Helpers.format_object(deal, @deal_fields)
        {:ok, %Result{status: :ok, content: formatted}}

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

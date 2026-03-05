# lib/assistant/skills/hubspot/deals/list_recent.ex — Handler for hubspot.list_recent_deals skill.
#
# Lists recently created or updated deals from HubSpot CRM with
# configurable limit. Returns a formatted list of deal summaries.
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (HubSpot API client)
#   - lib/assistant/skills/hubspot/helpers.ex (shared HubSpot helpers)
#   - priv/skills/hubspot/list_recent_deals.md (skill definition)

defmodule Assistant.Skills.HubSpot.Deals.ListRecent do
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
    limit = Helpers.parse_limit(Map.get(flags, "limit"))
    list_deals(hubspot, api_key, limit)
  end

  defp list_deals(hubspot, api_key, limit) do
    case hubspot.list_recent_deals(api_key, limit) do
      {:ok, deals} ->
        formatted = Helpers.format_object_list(deals, @deal_fields, "deals")
        {:ok, %Result{status: :ok, content: formatted}}

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

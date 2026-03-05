# lib/assistant/skills/hubspot/deals/search.ex — Handler for hubspot.search_deals skill.
#
# Searches for deals in HubSpot CRM. Supports searching by deal name
# (CONTAINS_TOKEN) or deal stage (EQ). Returns formatted list of matches.
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (HubSpot API client)
#   - lib/assistant/skills/hubspot/helpers.ex (shared HubSpot helpers)
#   - priv/skills/hubspot/search_deals.md (skill definition)

defmodule Assistant.Skills.HubSpot.Deals.Search do
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
    query = Map.get(flags, "query")

    if is_nil(query) || query == "" do
      {:ok, %Result{status: :error, content: "Missing required parameter: --query (search term)."}}
    else
      search_by = Map.get(flags, "search_by", "name")
      limit = Helpers.parse_limit(Map.get(flags, "limit"))

      case resolve_search_params(search_by, query) do
        {:ok, property, operator, value} ->
          search_deals(hubspot, api_key, property, operator, value, limit)

        {:error, message} ->
          {:ok, %Result{status: :error, content: message}}
      end
    end
  end

  defp resolve_search_params("name", query), do: {:ok, "dealname", "CONTAINS_TOKEN", query}
  defp resolve_search_params("stage", query), do: {:ok, "dealstage", "EQ", query}

  defp resolve_search_params(other, _query) do
    {:error, "Invalid --search_by value: \"#{other}\". Must be \"name\" or \"stage\"."}
  end

  defp search_deals(hubspot, api_key, property, operator, value, limit) do
    case hubspot.search_deals(api_key, property, operator, value, limit) do
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

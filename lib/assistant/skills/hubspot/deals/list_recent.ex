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
  @moduledoc false
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

    case hubspot.list_recent_deals(api_key, limit) do
      {:ok, deals} ->
        formatted = Helpers.format_object_list(deals, @deal_fields, "deals")
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

# lib/assistant/skills/hubspot/deals/get.ex — Handler for hubspot.get_deal skill.
#
# Retrieves a single deal from HubSpot CRM by ID and formats the result.
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (HubSpot API client)
#   - lib/assistant/skills/hubspot/helpers.ex (shared HubSpot helpers)
#   - priv/skills/hubspot/get_deal.md (skill definition)

defmodule Assistant.Skills.HubSpot.Deals.Get do
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
    id = Map.get(flags, "id")

    cond do
      is_nil(id) || id == "" ->
        {:ok, %Result{status: :error, content: "Missing required parameter: --id (deal ID)."}}

      not String.match?(id, ~r/^\d+$/) ->
        {:ok, %Result{status: :error, content: "Invalid --id: must be a numeric HubSpot ID."}}

      true ->
        case hubspot.get_deal(api_key, id) do
          {:ok, deal} ->
            formatted = Helpers.format_object(deal, Helpers.deal_fields())
            {:ok, %Result{status: :ok, content: formatted}}

          {:error, {:api_error, 404, _}} = error ->
            Helpers.handle_error(error, "deal", id)

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

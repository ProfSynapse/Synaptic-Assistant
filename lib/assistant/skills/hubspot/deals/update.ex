# lib/assistant/skills/hubspot/deals/update.ex — Handler for hubspot.update_deal skill.
#
# Updates an existing deal in HubSpot CRM. Requires the deal ID and at least
# one property to update. Builds a properties map from provided flags.
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (HubSpot API client)
#   - lib/assistant/skills/hubspot/helpers.ex (shared HubSpot helpers)
#   - priv/skills/hubspot/update_deal.md (skill definition)

defmodule Assistant.Skills.HubSpot.Deals.Update do
  @moduledoc false
  @behaviour Assistant.Skills.Handler

  require Logger

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
    id = Map.get(flags, "id")

    cond do
      is_nil(id) || id == "" ->
        {:ok, %Result{status: :error, content: "Missing required parameter: --id (deal ID)."}}

      not String.match?(id, ~r/^\d+$/) ->
        {:ok, %Result{status: :error, content: "Invalid --id: must be a numeric HubSpot ID."}}

      true ->
        case Helpers.parse_properties_json(Map.get(flags, "properties")) do
          {:error, message} ->
            {:ok, %Result{status: :error, content: message}}

          {:ok, extra_props} ->
            properties =
              %{}
              |> Helpers.maybe_put("dealname", Map.get(flags, "dealname"))
              |> Helpers.maybe_put("pipeline", Map.get(flags, "pipeline"))
              |> Helpers.maybe_put("dealstage", Map.get(flags, "dealstage"))
              |> Helpers.maybe_put("amount", Map.get(flags, "amount"))
              |> Helpers.maybe_put("closedate", Map.get(flags, "closedate"))
              |> Helpers.maybe_put("description", Map.get(flags, "description"))
              |> Map.merge(extra_props)

            if properties == %{} do
              {:ok,
               %Result{
                 status: :error,
                 content: "No properties to update. Provide at least one field (--dealname, --pipeline, --dealstage, --amount, --closedate, --description, or --properties)."
               }}
            else
              case hubspot.update_deal(api_key, id, properties) do
                {:ok, deal} ->
                  formatted = Helpers.format_object(deal, @deal_fields)

                  Logger.info("HubSpot deal updated", deal_id: id)

                  {:ok,
                   %Result{
                     status: :ok,
                     content: "Deal updated successfully.\n\n#{formatted}",
                     side_effects: [:hubspot_deal_updated],
                     metadata: %{deal_id: id}
                   }}

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
  end
end

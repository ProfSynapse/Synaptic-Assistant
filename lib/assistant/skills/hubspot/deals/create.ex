# lib/assistant/skills/hubspot/deals/create.ex — Handler for hubspot.create_deal skill.
#
# Creates a new deal in HubSpot CRM. Validates that dealname is provided,
# builds a properties map from optional flags, and delegates to the client.
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (HubSpot API client)
#   - lib/assistant/skills/hubspot/helpers.ex (shared HubSpot helpers)
#   - priv/skills/hubspot/create_deal.md (skill definition)

defmodule Assistant.Skills.HubSpot.Deals.Create do
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
    dealname = Map.get(flags, "dealname")

    if is_nil(dealname) || dealname == "" do
      {:ok, %Result{status: :error, content: "Missing required parameter: --dealname (deal name)."}}
    else
      case Helpers.parse_properties_json(Map.get(flags, "properties")) do
        {:error, message} ->
          {:ok, %Result{status: :error, content: message}}

        {:ok, extra_props} ->
          properties =
            %{"dealname" => dealname}
            |> Helpers.maybe_put("pipeline", Map.get(flags, "pipeline"))
            |> Helpers.maybe_put("dealstage", Map.get(flags, "dealstage"))
            |> Helpers.maybe_put("amount", Map.get(flags, "amount"))
            |> Helpers.maybe_put("closedate", Map.get(flags, "closedate"))
            |> Helpers.maybe_put("description", Map.get(flags, "description"))
            |> Map.merge(extra_props)

          case hubspot.create_deal(api_key, properties) do
            {:ok, deal} ->
              formatted = Helpers.format_object(deal, Helpers.deal_fields())

              Logger.info("HubSpot deal created", deal_id: deal[:id])

              {:ok,
               %Result{
                 status: :ok,
                 content: "Deal created successfully.\n\n#{formatted}",
                 side_effects: [:hubspot_deal_created],
                 metadata: %{deal_id: deal[:id]}
               }}

            {:error, {:api_error, 409, _}} = error ->
              Helpers.handle_error(error, "deal", "dealname")

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

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
      properties = build_properties(flags)

      case merge_extra_properties(properties, Map.get(flags, "properties")) do
        {:ok, final_properties} ->
          if map_size(final_properties) == 0 do
            {:ok, %Result{status: :error, content: "No properties to update. Provide at least one field to change."}}
          else
            update_deal(hubspot, api_key, id, final_properties)
          end

        {:error, message} ->
          {:ok, %Result{status: :error, content: message}}
      end
    end
  end

  defp build_properties(flags) do
    %{}
    |> Helpers.maybe_put("dealname", Map.get(flags, "dealname"))
    |> Helpers.maybe_put("pipeline", Map.get(flags, "pipeline"))
    |> Helpers.maybe_put("dealstage", Map.get(flags, "dealstage"))
    |> Helpers.maybe_put("amount", Map.get(flags, "amount"))
    |> Helpers.maybe_put("closedate", Map.get(flags, "closedate"))
    |> Helpers.maybe_put("description", Map.get(flags, "description"))
  end

  defp merge_extra_properties(properties, nil), do: {:ok, properties}
  defp merge_extra_properties(properties, ""), do: {:ok, properties}

  defp merge_extra_properties(properties, json_string) do
    case Jason.decode(json_string) do
      {:ok, extra} when is_map(extra) ->
        {:ok, Map.merge(properties, extra)}

      {:ok, _} ->
        {:error, "Invalid --properties: must be a JSON object (e.g. '{\"key\": \"value\"}')."}

      {:error, _} ->
        {:error, "Invalid --properties: could not parse JSON."}
    end
  end

  defp update_deal(hubspot, api_key, id, properties) do
    case hubspot.update_deal(api_key, id, properties) do
      {:ok, deal} ->
        Logger.info("HubSpot deal updated", deal_id: deal[:id])

        formatted = Helpers.format_object(deal, @deal_fields)

        {:ok,
         %Result{
           status: :ok,
           content: "Deal updated successfully.\n\n#{formatted}",
           side_effects: [:hubspot_deal_updated],
           metadata: %{deal_id: deal[:id]}
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

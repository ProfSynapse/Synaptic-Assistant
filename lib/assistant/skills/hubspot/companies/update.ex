# lib/assistant/skills/hubspot/companies/update.ex — Handler for hubspot.update_company skill.
#
# Updates an existing company in HubSpot CRM by ID. At least one property must
# be provided alongside the required ID.
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (HubSpot API client)
#   - lib/assistant/skills/hubspot/helpers.ex (shared HubSpot helpers)
#   - priv/skills/hubspot/update_company.md (skill definition)

defmodule Assistant.Skills.HubSpot.Companies.Update do
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
    id = Map.get(flags, "id")

    cond do
      is_nil(id) || id == "" ->
        {:ok, %Result{status: :error, content: "Missing required parameter: --id (company ID)."}}

      not String.match?(id, ~r/^\d+$/) ->
        {:ok, %Result{status: :error, content: "Invalid --id: must be a numeric HubSpot ID."}}

      true ->
        case Helpers.parse_properties_json(Map.get(flags, "properties")) do
          {:error, message} ->
            {:ok, %Result{status: :error, content: message}}

          {:ok, extra_props} ->
            properties =
              %{}
              |> Helpers.maybe_put("name", Map.get(flags, "name"))
              |> Helpers.maybe_put("domain", Map.get(flags, "domain"))
              |> Helpers.maybe_put("website", Map.get(flags, "website"))
              |> Helpers.maybe_put("industry", Map.get(flags, "industry"))
              |> Helpers.maybe_put("description", Map.get(flags, "description"))
              |> Map.merge(extra_props)

            if properties == %{} do
              {:ok,
               %Result{
                 status: :error,
                 content:
                   "No properties to update. Provide at least one field (--name, --domain, --website, --industry, --description, or --properties)."
               }}
            else
              case hubspot.update_company(api_key, id, properties) do
                {:ok, company} ->
                  formatted = Helpers.format_object(company, Helpers.company_fields())

                  Logger.info("HubSpot company updated", company_id: id)

                  {:ok,
                   %Result{
                     status: :ok,
                     content: "Company updated successfully.\n\n#{formatted}",
                     side_effects: [:hubspot_company_updated],
                     metadata: %{company_id: id}
                   }}

                {:error, {:api_error, 404, _}} = error ->
                  Helpers.handle_error(error, "company", id)

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

# lib/assistant/skills/hubspot/companies/create.ex — Handler for hubspot.create_company skill.
#
# Creates a new company in HubSpot CRM. Requires a company name; optionally
# accepts domain, website, industry, description, and arbitrary properties JSON.
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (HubSpot API client)
#   - lib/assistant/skills/hubspot/helpers.ex (shared HubSpot helpers)
#   - priv/skills/hubspot/create_company.md (skill definition)

defmodule Assistant.Skills.HubSpot.Companies.Create do
  @moduledoc false
  @behaviour Assistant.Skills.Handler

  require Logger

  alias Assistant.Skills.HubSpot.Helpers
  alias Assistant.Skills.Result

  @company_fields [
    {"Name", "name"},
    {"Domain", "domain"},
    {"Website", "website"},
    {"Industry", "industry"},
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
    name = Map.get(flags, "name")

    if is_nil(name) || name == "" do
      {:ok, %Result{status: :error, content: "Missing required parameter: --name (company name)."}}
    else
      case Helpers.parse_properties_json(Map.get(flags, "properties")) do
        {:error, message} ->
          {:ok, %Result{status: :error, content: message}}

        {:ok, extra_props} ->
          properties =
            %{"name" => name}
            |> Helpers.maybe_put("domain", Map.get(flags, "domain"))
            |> Helpers.maybe_put("website", Map.get(flags, "website"))
            |> Helpers.maybe_put("industry", Map.get(flags, "industry"))
            |> Helpers.maybe_put("description", Map.get(flags, "description"))
            |> Map.merge(extra_props)

          case hubspot.create_company(api_key, properties) do
            {:ok, company} ->
              formatted = Helpers.format_object(company, @company_fields)

              Logger.info("HubSpot company created", company_id: company[:id], name: name)

              {:ok,
               %Result{
                 status: :ok,
                 content: "Company created successfully.\n\n#{formatted}",
                 side_effects: [:hubspot_company_created],
                 metadata: %{company_id: company[:id]}
               }}

            {:error, {:api_error, 409, _}} = error ->
              Helpers.handle_error(error, "company", "name")

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

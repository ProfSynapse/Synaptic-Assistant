# lib/assistant/skills/hubspot/companies/list_recent.ex — Handler for hubspot.list_recent_companies skill.
#
# Lists recently created/updated companies from HubSpot CRM. Returns a formatted
# list capped by an optional limit parameter (default 10, max 50).
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (HubSpot API client)
#   - lib/assistant/skills/hubspot/helpers.ex (shared HubSpot helpers)
#   - priv/skills/hubspot/list_recent_companies.md (skill definition)

defmodule Assistant.Skills.HubSpot.Companies.ListRecent do
  @moduledoc false
  @behaviour Assistant.Skills.Handler

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
    limit = Helpers.parse_limit(Map.get(flags, "limit"))

    case hubspot.list_recent_companies(api_key, limit) do
      {:ok, companies} ->
        formatted = Helpers.format_object_list(companies, @company_fields, "companies")
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

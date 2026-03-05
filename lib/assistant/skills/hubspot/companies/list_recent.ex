# lib/assistant/skills/hubspot/companies/list_recent.ex — Handler for hubspot.list_recent_companies skill.
#
# Lists recently created/updated companies from HubSpot CRM. Returns a formatted
# list capped by an optional limit parameter (default 10, max 50).
# Supports cursor-based pagination via --after parameter.
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
    after_cursor = Map.get(flags, "after")

    case hubspot.list_recent_companies(api_key, limit, after_cursor) do
      {:ok, %{results: companies, next: next}} ->
        formatted = Helpers.format_object_list(companies, Helpers.company_fields(), "companies")
        content = Helpers.maybe_append_pagination(formatted, next)
        {:ok, %Result{status: :ok, content: content}}

      error ->
        Helpers.handle_error(error)
    end
  end
end

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
  @behaviour Assistant.Skills.Handler

  alias Assistant.Skills.HubSpot.Helpers
  alias Assistant.Skills.Result

  @company_fields [{"Name", "name"}, {"Domain", "domain"}, {"Website", "website"}, {"Industry", "industry"}, {"Description", "description"}]

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

  defp resolve_api_key do
    Assistant.IntegrationSettings.get(:hubspot_api_key)
  end

  defp do_execute(hubspot, api_key, flags) do
    limit = Helpers.parse_limit(Map.get(flags, "limit"))

    case hubspot.list_recent_companies(api_key, limit) do
      {:ok, companies} ->
        formatted = Helpers.format_object_list(companies, @company_fields, "companies")
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

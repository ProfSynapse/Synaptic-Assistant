# lib/assistant/skills/hubspot/companies/search.ex — Handler for hubspot.search_companies skill.
#
# Searches HubSpot CRM companies by name (CONTAINS_TOKEN) or domain (EQ).
# Returns a formatted list of matching companies, capped by a configurable limit.
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (HubSpot API client)
#   - lib/assistant/skills/hubspot/helpers.ex (shared HubSpot helpers)
#   - priv/skills/hubspot/search_companies.md (skill definition)

defmodule Assistant.Skills.HubSpot.Companies.Search do
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
    query = Map.get(flags, "query")

    if is_nil(query) || query == "" do
      {:ok, %Result{status: :error, content: "Missing required parameter: --query (search term)."}}
    else
      search_by = Map.get(flags, "search_by", "name")
      limit = Helpers.parse_limit(Map.get(flags, "limit"))

      {property, operator} = search_params(search_by)

      case hubspot.search_companies(api_key, property, operator, query, limit) do
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

  defp search_params("domain"), do: {"domain", "EQ"}
  defp search_params(_name), do: {"name", "CONTAINS_TOKEN"}
end

# lib/assistant/skills/hubspot/companies/get.ex — Handler for hubspot.get_company skill.
#
# Retrieves a single company from HubSpot CRM by ID. Returns formatted company
# details including name, domain, website, industry, and description.
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (HubSpot API client)
#   - lib/assistant/skills/hubspot/helpers.ex (shared HubSpot helpers)
#   - priv/skills/hubspot/get_company.md (skill definition)

defmodule Assistant.Skills.HubSpot.Companies.Get do
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
    id = Map.get(flags, "id")

    if is_nil(id) || id == "" do
      {:ok, %Result{status: :error, content: "Missing required parameter: --id (company ID)."}}
    else
      case hubspot.get_company(api_key, id) do
        {:ok, company} ->
          formatted = Helpers.format_object(company, @company_fields)
          {:ok, %Result{status: :ok, content: formatted}}

        {:error, {:api_error, 404, _}} ->
          {:ok, %Result{status: :error, content: "No company found with ID #{id}."}}

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
end

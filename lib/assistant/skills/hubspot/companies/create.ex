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
  @behaviour Assistant.Skills.Handler

  require Logger

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
    name = Map.get(flags, "name")

    if is_nil(name) || name == "" do
      {:ok, %Result{status: :error, content: "Missing required parameter: --name (company name)."}}
    else
      properties =
        %{"name" => name}
        |> Helpers.maybe_put("domain", Map.get(flags, "domain"))
        |> Helpers.maybe_put("website", Map.get(flags, "website"))
        |> Helpers.maybe_put("industry", Map.get(flags, "industry"))
        |> Helpers.maybe_put("description", Map.get(flags, "description"))
        |> merge_extra_properties(Map.get(flags, "properties"))

      case properties do
        {:error, message} ->
          {:ok, %Result{status: :error, content: message}}

        props ->
          case hubspot.create_company(api_key, props) do
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

            {:error, {:api_error, 409, _}} ->
              {:ok, %Result{status: :error, content: "A company with this name already exists."}}

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

  defp merge_extra_properties(props, nil), do: props
  defp merge_extra_properties(props, ""), do: props

  defp merge_extra_properties(props, json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, extra} when is_map(extra) -> Map.merge(props, extra)
      {:ok, _} -> {:error, "Invalid --properties: must be a JSON object."}
      {:error, _} -> {:error, "Invalid --properties: not valid JSON."}
    end
  end

  defp merge_extra_properties(props, _), do: props
end

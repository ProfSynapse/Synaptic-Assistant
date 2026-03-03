# lib/assistant/integrations/hubspot/client.ex — HubSpot API HTTP client.
#
# Provides functions for interacting with the HubSpot API via Req.
# Used by ConnectionValidator for health checks.
#
# Related files:
#   - lib/assistant/integration_settings/connection_validator.ex (consumer)

defmodule Assistant.Integrations.HubSpot.Client do
  @moduledoc """
  HubSpot API HTTP client.

  Sends requests to the HubSpot API using `Req`. The API key is read
  from `IntegrationSettings` (DB → env var fallback).

  ## Usage

      # Health check — verify the API key works
      HubSpot.Client.health_check("pat-xxx")
  """

  require Logger

  @default_base_url "https://api.hubapi.com"

  @doc """
  Verify HubSpot API connectivity with a lightweight contacts query.

  ## Parameters

    * `api_key` - The HubSpot private app token

  ## Returns

    * `{:ok, :healthy}` — API key is valid and API is reachable
    * `{:error, reason}` — API error or network failure
  """
  @spec health_check(String.t()) :: {:ok, :healthy} | {:error, term()}
  def health_check(api_key) do
    url = "#{base_url()}/crm/v3/objects/contacts"

    case Req.get(url,
           params: [limit: 1],
           headers: [{"authorization", "Bearer #{api_key}"}],
           receive_timeout: 5_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200}} ->
        {:ok, :healthy}

      {:ok, %Req.Response{status: status, body: body}} ->
        message = extract_error_message(body)
        Logger.warning("HubSpot API error", status: status, message: message)
        {:error, {:api_error, status, message}}

      {:error, reason} ->
        Logger.error("HubSpot API request failed", reason: Exception.message(reason))
        {:error, {:request_failed, reason}}
    end
  end

  defp base_url do
    Application.get_env(:assistant, :hubspot_api_base_url, @default_base_url)
  end

  defp extract_error_message(%{"message" => message}), do: message
  defp extract_error_message(body) when is_map(body), do: inspect(body)
  defp extract_error_message(body), do: to_string(body)
end

# lib/assistant/integration_settings/connection_validator.ex — Real API handshake validation.
#
# Validates integration connections by making actual API calls to each service.
# Used by the settings page to show accurate connection status (green check)
# instead of relying on key existence alone.
#
# Each integration has a validator function registered in @validators. Adding a
# new integration requires one tuple in @validators and one defp clause for
# run_validator/2.
#
# Related files:
#   - lib/assistant/integration_settings.ex (reads configured keys)
#   - lib/assistant/integrations/telegram/client.ex (Telegram health check)
#   - lib/assistant/integrations/discord/client.ex (Discord health check)
#   - lib/assistant/integrations/slack/client.ex (Slack auth test)
#   - lib/assistant/integrations/google/auth.ex (Google token validation)
#   - lib/assistant_web/live/settings_live/loaders.ex (consumer)

defmodule Assistant.IntegrationSettings.ConnectionValidator do
  @moduledoc """
  Validates integration connections via real API handshakes.

  Runs parallel API health checks for each configured integration and returns
  a map of `%{group_string => :connected | :not_connected | :not_configured}`.

  ## Usage

      results = ConnectionValidator.validate_all(user_id)
      # => %{"telegram" => :connected, "discord" => :not_connected, ...}

  ## Adding a New Integration

  1. Add a `{group_string}` entry to `@validators`
  2. Add a `defp run_validator(group_string, user_id)` clause returning the result
  """

  alias Assistant.IntegrationSettings
  alias Assistant.Integrations.Discord
  alias Assistant.Integrations.Google.Auth
  alias Assistant.Integrations.Slack
  alias Assistant.Integrations.Telegram

  require Logger

  @type result :: :connected | :not_connected | :not_configured

  @default_hubspot_base_url "https://api.hubapi.com"
  @default_elevenlabs_base_url "https://api.elevenlabs.io"

  @validators [
    "google_workspace",
    "telegram",
    "slack",
    "discord",
    "google_chat",
    "hubspot",
    "elevenlabs"
  ]

  @doc """
  Run all integration validators in parallel and return status per group.

  `user_id` is required for Google OAuth (per-user tokens). Pass `nil` when
  the settings user has no linked chat user — Google will return `:not_configured`.

  Returns `%{String.t() => :connected | :not_connected | :not_configured}`.
  """
  @spec validate_all(String.t() | nil) :: %{String.t() => result()}
  def validate_all(user_id) do
    @validators
    |> Task.async_stream(
      fn group ->
        result =
          try do
            run_validator(group, user_id)
          rescue
            error ->
              Logger.warning("Connection validation failed for #{group}",
                error: Exception.message(error)
              )

              :not_connected
          catch
            :exit, _ -> :not_connected
          end

        {group, result}
      end,
      max_concurrency: 7,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.zip(@validators)
    |> Enum.reduce(%{}, fn
      {{:ok, {group, result}}, _group}, acc -> Map.put(acc, group, result)
      {{:exit, _reason}, group}, acc -> Map.put(acc, group, :not_connected)
    end)
  end

  # --- Validators ---

  defp run_validator("google_workspace", nil), do: :not_configured

  defp run_validator("google_workspace", user_id) do
    case Auth.user_token(user_id) do
      {:ok, _token} -> :connected
      {:error, :not_connected} -> :not_configured
      {:error, _} -> :not_connected
    end
  end

  defp run_validator("telegram", _user_id) do
    case IntegrationSettings.get(:telegram_bot_token) do
      nil ->
        :not_configured

      _token ->
        case Telegram.Client.get_me() do
          {:ok, _} -> :connected
          {:error, _} -> :not_connected
        end
    end
  end

  defp run_validator("slack", _user_id) do
    case IntegrationSettings.get(:slack_bot_token) do
      nil ->
        :not_configured

      token ->
        case Slack.Client.auth_test(token) do
          {:ok, _} -> :connected
          {:error, _} -> :not_connected
        end
    end
  end

  defp run_validator("discord", _user_id) do
    case IntegrationSettings.get(:discord_bot_token) do
      nil ->
        :not_configured

      _token ->
        case Discord.Client.get_gateway() do
          {:ok, _} -> :connected
          {:error, _} -> :not_connected
        end
    end
  end

  defp run_validator("google_chat", _user_id) do
    case Auth.service_token() do
      {:ok, _token} -> :connected
      {:error, :not_configured} -> :not_configured
      {:error, _} -> :not_connected
    end
  end

  defp run_validator("hubspot", _user_id) do
    case IntegrationSettings.get(:hubspot_api_key) do
      nil ->
        :not_configured

      token ->
        url = "#{hubspot_base_url()}/crm/v3/objects/contacts"

        case Req.get(url,
               params: [limit: 1],
               headers: [{"authorization", "Bearer #{token}"}],
               receive_timeout: 5_000,
               retry: false
             ) do
          {:ok, %Req.Response{status: 200}} -> :connected
          {:ok, %Req.Response{}} -> :not_connected
          {:error, _} -> :not_connected
        end
    end
  end

  defp run_validator("elevenlabs", _user_id) do
    case IntegrationSettings.get(:elevenlabs_api_key) do
      nil ->
        :not_configured

      key ->
        url = "#{elevenlabs_base_url()}/v1/user"

        case Req.get(url,
               headers: [{"xi-api-key", key}],
               receive_timeout: 5_000,
               retry: false
             ) do
          {:ok, %Req.Response{status: 200}} -> :connected
          {:ok, %Req.Response{}} -> :not_connected
          {:error, _} -> :not_connected
        end
    end
  end

  defp hubspot_base_url do
    Application.get_env(:assistant, :hubspot_api_base_url, @default_hubspot_base_url)
  end

  defp elevenlabs_base_url do
    Application.get_env(:assistant, :elevenlabs_api_base_url, @default_elevenlabs_base_url)
  end
end

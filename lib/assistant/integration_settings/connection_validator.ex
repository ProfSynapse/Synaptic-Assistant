# lib/assistant/integration_settings/connection_validator.ex — Real API handshake validation.
#
# Validates integration connections by making actual API calls to each service.
# Used by the settings page to show accurate connection status (green check)
# instead of relying on key existence alone.
#
# Each integration has a validator function registered in @validators. Adding a
# new integration requires one entry in @validators and one defp clause for
# run_validator/2.
#
# Related files:
#   - lib/assistant/integration_settings.ex (reads configured keys)
#   - lib/assistant/integrations/telegram/client.ex (Telegram health check)
#   - lib/assistant/integrations/discord/client.ex (Discord health check)
#   - lib/assistant/integrations/slack/client.ex (Slack auth test)
#   - lib/assistant/integrations/hubspot/client.ex (HubSpot health check)
#   - lib/assistant/integrations/elevenlabs/client.ex (ElevenLabs health check)
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

      result = ConnectionValidator.validate_one("telegram", user_id)
      # => :connected

  ## Adding a New Integration

  1. Add a `{group_string}` entry to `@validators`
  2. Add a `defp run_validator(group_string, user_id)` clause returning the result
  """

  alias Assistant.IntegrationSettings
  alias Assistant.Integrations.Discord
  alias Assistant.Integrations.ElevenLabs
  alias Assistant.Integrations.Google.Auth
  alias Assistant.Integrations.HubSpot
  alias Assistant.Integrations.Slack
  alias Assistant.Integrations.Telegram

  require Logger

  @type result :: :connected | :not_connected | :not_configured

  @validators ~w(google_workspace telegram slack discord google_chat hubspot elevenlabs)

  @validators_set MapSet.new(@validators)

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
      fn group -> {group, safe_run(group, user_id)} end,
      max_concurrency: 7,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.zip(@validators)
    |> Map.new(fn
      {{:ok, {group, result}}, _group} -> {group, result}
      {{:exit, _reason}, group} -> {group, :not_connected}
    end)
  end

  @doc """
  Validate a single integration group.

  Returns the status directly (no map wrapping). Useful for targeted rechecks
  after saving a key, without re-validating all integrations.

  Returns `:not_configured` if the group is not in the validator registry.
  """
  @spec validate_one(String.t(), String.t() | nil) :: result()
  def validate_one(group, user_id) do
    if MapSet.member?(@validators_set, group) do
      safe_run(group, user_id)
    else
      :not_configured
    end
  end

  # Wraps run_validator with rescue/catch for resilience.
  defp safe_run(group, user_id) do
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
        case HubSpot.Client.health_check(token) do
          {:ok, _} -> :connected
          {:error, _} -> :not_connected
        end
    end
  end

  defp run_validator("elevenlabs", _user_id) do
    case IntegrationSettings.get(:elevenlabs_api_key) do
      nil ->
        :not_configured

      key ->
        case ElevenLabs.Client.health_check(key) do
          {:ok, _} -> :connected
          {:error, _} -> :not_connected
        end
    end
  end
end

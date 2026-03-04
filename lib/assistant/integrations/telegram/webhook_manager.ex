# lib/assistant/integrations/telegram/webhook_manager.ex — Auto-registers Telegram webhook.
#
# Called as a post-save side effect when Telegram integration settings change.
# Derives the webhook URL from the Phoenix Endpoint config and calls the
# Telegram Bot API to set or delete the webhook.
#
# Related files:
#   - lib/assistant/integration_settings.ex (calls maybe_sync_telegram_webhook/1 after put/3)
#   - lib/assistant/integrations/telegram/client.ex (HTTP client for set_webhook/delete_webhook)
#   - lib/assistant_web/router.ex (webhook route: POST /webhooks/telegram)

defmodule Assistant.Integrations.Telegram.WebhookManager do
  @moduledoc """
  Manages automatic Telegram webhook registration.

  When Telegram integration settings are saved, this module determines whether
  to register or deregister the webhook with the Telegram Bot API.

  The webhook URL is derived from the Phoenix Endpoint URL config (which uses
  `PHX_HOST` in production). Registration is fire-and-forget — failures are
  logged but never block the settings save.
  """

  alias Assistant.IntegrationSettings
  alias Assistant.Integrations.Telegram.Client

  require Logger

  @telegram_keys MapSet.new([
                   :telegram_bot_token,
                   :telegram_webhook_secret,
                   :telegram_enabled
                 ])

  @webhook_path "/webhooks/telegram"

  @doc """
  Sync the Telegram webhook if the changed key is Telegram-related.

  Called after a successful `IntegrationSettings.put/3`. Runs the actual
  API call in a spawned task so it never blocks the caller.

  Returns `:ok` immediately (fire-and-forget).
  """
  @spec maybe_sync(atom()) :: :ok
  def maybe_sync(key) when is_atom(key) do
    if MapSet.member?(@telegram_keys, key) do
      Task.start(fn -> sync_webhook() end)
    end

    :ok
  end

  @doc """
  Synchronously register or deregister the Telegram webhook based on
  current integration settings.

  Returns `{:ok, :registered}`, `{:ok, :deregistered}`, `{:ok, :skipped}`,
  or `{:error, reason}`.
  """
  @spec sync_webhook() :: {:ok, :registered | :deregistered | :skipped} | {:error, term()}
  def sync_webhook do
    enabled = IntegrationSettings.get(:telegram_enabled)
    bot_token = IntegrationSettings.get(:telegram_bot_token)
    webhook_secret = IntegrationSettings.get(:telegram_webhook_secret)

    cond do
      explicitly_disabled?(enabled) ->
        deregister_webhook()

      is_nil(bot_token) or bot_token == "" ->
        Logger.info("Telegram webhook sync skipped: no bot token configured")
        {:ok, :skipped}

      true ->
        register_webhook(webhook_secret)
    end
  end

  # --- Private ---

  defp register_webhook(webhook_secret) do
    case build_webhook_url() do
      {:ok, url} ->
        opts =
          []
          |> maybe_put_secret_token(webhook_secret)
          |> Keyword.put(:allowed_updates, ["message"])

        case Client.set_webhook(url, opts) do
          {:ok, _result} ->
            Logger.info("Telegram webhook registered", url: url)
            {:ok, :registered}

          {:error, reason} ->
            Logger.warning("Telegram webhook registration failed",
              url: url,
              reason: inspect(reason)
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Telegram webhook sync skipped: #{reason}")
        {:error, reason}
    end
  end

  defp deregister_webhook do
    # delete_webhook needs a valid bot token to call the API.
    # If there's no token, there's nothing to deregister.
    case IntegrationSettings.get(:telegram_bot_token) do
      nil ->
        {:ok, :skipped}

      "" ->
        {:ok, :skipped}

      _token ->
        case Client.delete_webhook() do
          {:ok, _result} ->
            Logger.info("Telegram webhook deregistered")
            {:ok, :deregistered}

          {:error, reason} ->
            Logger.warning("Telegram webhook deregistration failed",
              reason: inspect(reason)
            )

            {:error, reason}
        end
    end
  end

  defp build_webhook_url do
    base_url = AssistantWeb.Endpoint.url()

    with true <- is_binary(base_url) and base_url != "",
         %URI{scheme: scheme, host: host} <- URI.parse(base_url),
         :ok <- validate_public_endpoint(scheme, host) do
      {:ok, base_url <> @webhook_path}
    else
      _ -> {:error, "endpoint URL not suitable for webhook (#{inspect(base_url)})"}
    end
  end

  defp explicitly_disabled?(value), do: value == "false"

  defp maybe_put_secret_token(opts, secret)
       when is_binary(secret) and secret != "" do
    Keyword.put(opts, :secret_token, secret)
  end

  defp maybe_put_secret_token(opts, _secret), do: opts

  defp validate_public_endpoint("https", host)
       when is_binary(host) and host not in ["localhost", "127.0.0.1"] do
    :ok
  end

  defp validate_public_endpoint(_, _), do: {:error, :invalid_endpoint}
end

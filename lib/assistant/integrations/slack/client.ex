# lib/assistant/integrations/slack/client.ex — Slack Web API HTTP client.
#
# Provides functions for interacting with the Slack Web API via Req.
# All functions accept a bot_token as the first parameter since Slack tokens
# are per-workspace (stored in oauth_tokens after OAuth2 V2 install flow).
#
# Related files:
#   - lib/assistant/channels/slack.ex (channel adapter that calls this)
#   - lib/assistant_web/controllers/slack_controller.ex (webhook handler)
#   - lib/assistant/schemas/oauth_token.ex (bot token storage)

defmodule Assistant.Integrations.Slack.Client do
  @moduledoc """
  Slack Web API HTTP client.

  Sends requests to the Slack Web API using `Req`. All functions require a
  `bot_token` as the first parameter (per-workspace OAuth2 bot token).

  ## Usage

      # Send a message
      Slack.Client.post_message(bot_token, "C12345", "Hello!")

      # Send a threaded reply
      Slack.Client.post_message(bot_token, "C12345", "Reply",
        thread_ts: "1234567890.123456"
      )

      # Health check
      Slack.Client.auth_test(bot_token)
  """

  require Logger

  @base_url "https://slack.com/api"

  @doc """
  Send a message to a Slack channel.

  ## Parameters

    * `bot_token` - The workspace bot OAuth token
    * `channel_id` - The channel ID (e.g., `"C12345678"`)
    * `text` - The message text (Slack mrkdwn format)
    * `opts` - Options:
      * `:thread_ts` - Thread timestamp for threaded replies
      * `:unfurl_links` - Whether to unfurl URLs (default: false)

  ## Returns

    * `{:ok, result}` — The posted message object
    * `{:error, reason}` — API or network error
  """
  @spec post_message(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def post_message(bot_token, channel_id, text, opts \\ []) do
    body =
      %{channel: channel_id, text: text}
      |> maybe_put(:thread_ts, Keyword.get(opts, :thread_ts))
      |> maybe_put(:unfurl_links, Keyword.get(opts, :unfurl_links))

    post(bot_token, "chat.postMessage", body)
  end

  @doc """
  Send an ephemeral message visible only to one user.

  ## Parameters

    * `bot_token` - The workspace bot OAuth token
    * `channel_id` - The channel ID
    * `user_id` - The user to show the message to
    * `text` - The message text
  """
  @spec post_ephemeral(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def post_ephemeral(bot_token, channel_id, user_id, text) do
    body = %{channel: channel_id, user: user_id, text: text}
    post(bot_token, "chat.postEphemeral", body)
  end

  @doc """
  Test authentication and get bot identity info.

  ## Parameters

    * `bot_token` - The workspace bot OAuth token
  """
  @spec auth_test(String.t()) :: {:ok, map()} | {:error, term()}
  def auth_test(bot_token) do
    post(bot_token, "auth.test", %{})
  end

  @doc """
  Get information about a channel.

  ## Parameters

    * `bot_token` - The workspace bot OAuth token
    * `channel_id` - The channel ID
  """
  @spec conversations_info(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def conversations_info(bot_token, channel_id) do
    post(bot_token, "conversations.info", %{channel: channel_id})
  end

  # --- HTTP Helpers ---

  defp post(bot_token, method, body) do
    url = "#{@base_url}/#{method}"

    case Req.post(url,
           json: body,
           headers: [{"authorization", "Bearer #{bot_token}"}]
         ) do
      {:ok, %Req.Response{status: 200, body: %{"ok" => true} = resp}} ->
        {:ok, resp}

      {:ok, %Req.Response{status: 200, body: %{"ok" => false, "error" => error}}} ->
        Logger.warning("Slack API error",
          method: method,
          error: error
        )

        {:error, {:api_error, error}}

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        Logger.warning("Slack API HTTP error",
          method: method,
          status: status,
          body: inspect(resp_body)
        )

        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        Logger.error("Slack API request failed",
          method: method,
          reason: inspect(reason)
        )

        {:error, {:request_failed, reason}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

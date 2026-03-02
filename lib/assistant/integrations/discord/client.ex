# lib/assistant/integrations/discord/client.ex — Discord Bot API HTTP client.
#
# Provides functions for interacting with the Discord Bot API via Req.
# Used by the Discord channel adapter for sending replies and typing indicators.
#
# Related files:
#   - lib/assistant/channels/discord.ex (channel adapter that calls this)
#   - lib/assistant_web/controllers/discord_controller.ex (webhook handler)
#   - lib/assistant_web/plugs/discord_auth.ex (webhook verification)

defmodule Assistant.Integrations.Discord.Client do
  @moduledoc """
  Discord Bot API HTTP client.

  Sends requests to the Discord API using `Req`. The bot token is read
  from application config (`:discord_bot_token`).

  ## Usage

      # Send a message
      Discord.Client.send_message("123456789", "Hello!")

      # Send a typing indicator
      Discord.Client.trigger_typing("123456789")

      # Health check
      Discord.Client.get_gateway()
  """

  alias Assistant.IntegrationSettings

  require Logger

  @default_base_url "https://discord.com/api/v10"
  @max_message_length 2000

  @doc """
  Send a text message to a Discord channel.

  ## Parameters

    * `channel_id` - The channel ID (snowflake string)
    * `text` - The message text (max 2000 characters)
    * `opts` - Options:
      * `:thread_id` - Thread ID to send message in

  ## Returns

    * `{:ok, result}` — The sent message object
    * `{:error, reason}` — API or network error
  """
  @spec send_message(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_message(channel_id, text, opts \\ []) do
    truncated_text = truncate_message(text)

    # If thread_id is specified, send to that thread (channel) instead
    target_channel = Keyword.get(opts, :thread_id, channel_id)

    body = %{content: truncated_text}

    post("/channels/#{target_channel}/messages", body)
  end

  @doc """
  Send a typing indicator to a Discord channel.

  Triggers the "Bot is typing..." indicator for ~10 seconds.

  ## Parameters

    * `channel_id` - The channel ID
  """
  @spec trigger_typing(String.t()) :: {:ok, term()} | {:error, term()}
  def trigger_typing(channel_id) do
    post("/channels/#{channel_id}/typing", %{})
  end

  @doc """
  Get the Gateway URL (health check / connectivity test).

  ## Returns

    * `{:ok, result}` — The gateway object with `url` field
    * `{:error, reason}` — API or network error
  """
  @spec get_gateway() :: {:ok, map()} | {:error, term()}
  def get_gateway do
    get("/gateway")
  end

  # --- HTTP Helpers ---

  defp post(path, body) do
    with {:ok, token} <- get_token() do
      url = "#{base_url()}#{path}"

      case Req.post(url,
             json: body,
             headers: [{"authorization", "Bot #{token}"}]
           ) do
        {:ok, %Req.Response{status: 204}} ->
          {:ok, :no_content}

        {:ok, %Req.Response{status: status, body: resp_body}}
        when status in 200..299 ->
          {:ok, resp_body}

        {:ok, %Req.Response{status: status, body: resp_body}} ->
          message = extract_error_message(resp_body)

          Logger.warning("Discord API error",
            path: path,
            status: status,
            message: message
          )

          {:error, {:api_error, status, message}}

        {:error, reason} ->
          Logger.error("Discord API request failed",
            path: path,
            reason: inspect(reason)
          )

          {:error, {:request_failed, reason}}
      end
    end
  end

  defp get(path) do
    with {:ok, token} <- get_token() do
      url = "#{base_url()}#{path}"

      case Req.get(url,
             headers: [{"authorization", "Bot #{token}"}]
           ) do
        {:ok, %Req.Response{status: 200, body: resp_body}} ->
          {:ok, resp_body}

        {:ok, %Req.Response{status: status, body: resp_body}} ->
          message = extract_error_message(resp_body)

          Logger.warning("Discord API error",
            path: path,
            status: status,
            message: message
          )

          {:error, {:api_error, status, message}}

        {:error, reason} ->
          Logger.error("Discord API request failed",
            path: path,
            reason: inspect(reason)
          )

          {:error, {:request_failed, reason}}
      end
    end
  end

  defp base_url do
    Application.get_env(:assistant, :discord_api_base_url, @default_base_url)
  end

  defp get_token do
    case IntegrationSettings.get(:discord_bot_token) do
      nil ->
        Logger.error("discord_bot_token not configured")
        {:error, :token_not_configured}

      token ->
        {:ok, token}
    end
  end

  defp truncate_message(text) do
    if String.length(text) <= @max_message_length do
      text
    else
      max = @max_message_length - 40
      String.slice(text, 0, max) <> "\n\n[Message truncated]"
    end
  end

  defp extract_error_message(%{"message" => message}), do: message
  defp extract_error_message(body) when is_map(body), do: inspect(body)
  defp extract_error_message(body), do: to_string(body)
end

# lib/assistant/integrations/google/chat.ex — Google Chat REST API client.
#
# Provides functions for sending messages to Google Chat spaces via the
# REST API. Uses service account authentication via Google.Auth.
#
# Related files:
#   - lib/assistant/integrations/google/auth.ex (token provider)
#   - lib/assistant/channels/google_chat.ex (channel adapter that calls this)
#   - lib/assistant_web/controllers/google_chat_controller.ex (async reply)

defmodule Assistant.Integrations.Google.Chat do
  @moduledoc """
  Google Chat REST API client for sending messages.

  Sends messages to Google Chat spaces using service account authentication.
  Supports threaded replies via the `thread_name` option.

  ## Usage

      # Simple message
      Google.Chat.send_message("spaces/AAAA_BBBB", "Hello!")

      # Threaded reply
      Google.Chat.send_message("spaces/AAAA_BBBB", "Reply text",
        thread_name: "spaces/AAAA_BBBB/threads/CCCC_DDDD"
      )
  """

  alias Assistant.Integrations.Google.Auth

  require Logger

  @base_url "https://chat.googleapis.com/v1"
  @max_message_bytes 32_000
  @valid_space_name ~r/^spaces\/[A-Za-z0-9_-]+$/

  @doc """
  Send a text message to a Google Chat space.

  ## Parameters

    * `space_name` - The space resource name (e.g., `"spaces/AAAA_BBBB"`)
    * `text` - The message text (max 32,000 bytes)
    * `opts` - Options:
      * `:thread_name` - Thread resource name for threaded replies

  ## Returns

    * `{:ok, response_body}` on success
    * `{:error, reason}` on failure
  """
  @spec send_message(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_message(space_name, text, opts \\ []) do
    unless Regex.match?(@valid_space_name, space_name) do
      Logger.warning("Rejected invalid space_name format",
        space_name: inspect(String.slice(space_name, 0, 40))
      )

      {:error, :invalid_space_name}
    else
      do_send_message(space_name, text, opts)
    end
  end

  defp do_send_message(space_name, text, opts) do
    thread_name = Keyword.get(opts, :thread_name)
    truncated_text = truncate_message(text)

    with {:ok, token} <- Auth.token() do
      body = build_body(truncated_text, thread_name)
      query_params = build_query_params(thread_name)
      url = "#{@base_url}/#{space_name}/messages"

      case Req.post(url,
             json: body,
             params: query_params,
             headers: [{"authorization", "Bearer #{token}"}]
           ) do
        {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
          {:ok, resp_body}

        {:ok, %Req.Response{status: status, body: resp_body}} ->
          Logger.warning("Google Chat API error",
            status: status,
            space: space_name,
            body: inspect(resp_body)
          )

          {:error, {:api_error, status, resp_body}}

        {:error, reason} ->
          Logger.error("Google Chat API request failed",
            space: space_name,
            reason: inspect(reason)
          )

          {:error, {:request_failed, reason}}
      end
    end
  end

  # --- Helpers ---

  defp build_body(text, nil), do: %{"text" => text}

  defp build_body(text, thread_name) do
    %{
      "text" => text,
      "thread" => %{"name" => thread_name}
    }
  end

  defp build_query_params(nil), do: []

  defp build_query_params(_thread_name) do
    [messageReplyOption: "REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD"]
  end

  # Truncate messages exceeding the 32KB limit to avoid API errors.
  defp truncate_message(text) when byte_size(text) <= @max_message_bytes, do: text

  defp truncate_message(text) do
    # Leave room for truncation notice
    max = @max_message_bytes - 50
    truncated = String.slice(text, 0, max)
    truncated <> "\n\n[Message truncated due to length limit]"
  end
end

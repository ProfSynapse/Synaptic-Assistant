# lib/assistant/notifications/google_chat.ex — Google Chat incoming webhook sender.
#
# Posts simple text messages to a Google Chat space via an incoming webhook URL.
# Used by the Notifications Router to deliver alerts to configured channels.

defmodule Assistant.Notifications.GoogleChat do
  @moduledoc """
  Sends notifications to Google Chat via incoming webhooks.

  Uses `Req` to POST a JSON text message. Returns `:ok` on success
  or `{:error, reason}` on failure.
  """

  require Logger

  @doc """
  Sends a text message to a Google Chat incoming webhook.

  ## Parameters
    - `webhook_url` — the full incoming webhook URL
    - `message` — the text content to send
    - `opts` — reserved for future use (e.g., card formatting)

  ## Returns
    - `:ok` on successful delivery (HTTP 2xx)
    - `{:error, reason}` on failure
  """
  @spec send(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def send(webhook_url, message, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)

    case Req.post(webhook_url,
           json: %{"text" => message},
           receive_timeout: timeout,
           retry: false
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        Logger.info("Google Chat notification sent",
          status: status,
          message_length: String.length(message)
        )

        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Google Chat webhook returned non-2xx",
          status: status,
          body: inspect(body)
        )

        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.error("Google Chat webhook request failed",
          error: inspect(reason)
        )

        {:error, reason}
    end
  end
end

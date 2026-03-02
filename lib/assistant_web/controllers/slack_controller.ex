# lib/assistant_web/controllers/slack_controller.ex — Slack Events API webhook controller.
#
# Handles incoming Slack Events API callback requests. HMAC-SHA256 signature
# verification is performed by the SlackAuth plug (applied in the router).
# This controller handles the url_verification handshake, normalizes events,
# and delegates message processing to the shared Dispatcher.
#
# Slack expects a 200 response within 3 seconds for all webhook requests;
# non-200 responses cause Slack to retry delivery.
#
# Related files:
#   - lib/assistant_web/plugs/slack_auth.ex (HMAC signature verification)
#   - lib/assistant/channels/slack.ex (event normalization + reply sending)
#   - lib/assistant/channels/dispatcher.ex (shared async dispatch logic)
#   - lib/assistant_web/router.ex (route definition)

defmodule AssistantWeb.SlackController do
  @moduledoc """
  Webhook controller for Slack Events API callbacks.

  ## Flow

    1. SlackAuth plug verifies the HMAC-SHA256 signature (returns 401 on failure)
    2. For `url_verification` type: responds with the challenge value (Slack handshake)
    3. For `event_callback` type:
       a. Checks for retry header (returns 200 immediately on retries)
       b. Extracts the event object
       c. Normalizes via `Channels.Slack`
       d. Dispatches to `Channels.Dispatcher` for async processing
    4. Always returns 200 to prevent Slack from retrying
  """

  use AssistantWeb, :controller

  alias Assistant.Channels.Dispatcher
  alias Assistant.Channels.Slack, as: SlackAdapter

  require Logger

  @doc """
  Handle a Slack Events API callback.

  The SlackAuth plug has already verified the HMAC signature by this point.
  """
  def event(conn, %{"type" => "url_verification", "challenge" => challenge}) do
    # Slack handshake: respond with the challenge value
    Logger.info("Slack url_verification challenge received")
    json(conn, %{"challenge" => challenge})
  end

  def event(conn, %{"type" => "event_callback", "event" => event_data} = params) do
    # Check for retries — return 200 immediately to prevent duplicate processing
    if retry?(conn) do
      Logger.debug("Slack retry detected, acknowledging without processing",
        retry_num: get_retry_num(conn)
      )

      json(conn, %{})
    else
      # Inject team_id from envelope into event data for globally unique IDs
      team_id = params["team_id"]
      enriched_event = Map.put(event_data, "_team_id", team_id)
      handle_event(conn, enriched_event)
    end
  end

  def event(conn, _params) do
    # Unknown callback type — acknowledge
    json(conn, %{})
  end

  # --- Event Handling ---

  defp handle_event(conn, event_data) do
    case SlackAdapter.normalize(event_data) do
      {:ok, message} ->
        Logger.info("Slack message received",
          channel_id: message.space_id,
          user_id: message.user_id,
          event_type: message.metadata["event_type"]
        )

        Dispatcher.dispatch(SlackAdapter, message)

        # Slack expects 200 within 3 seconds — always acknowledge
        json(conn, %{})

      {:error, :ignored} ->
        # Bot message, subtype, or unrecognized event — acknowledge
        json(conn, %{})
    end
  end

  # --- Retry Detection ---

  defp retry?(conn) do
    case get_req_header(conn, "x-slack-retry-num") do
      [_num] -> true
      _ -> false
    end
  end

  defp get_retry_num(conn) do
    case get_req_header(conn, "x-slack-retry-num") do
      [num] -> num
      _ -> nil
    end
  end
end

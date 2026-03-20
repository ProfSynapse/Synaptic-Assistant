# test/assistant_web/controllers/slack_controller_test.exs
#
# Integration tests for the Slack webhook controller.
# Tests the full request pipeline: SlackAuth plug → controller → response.
# Uses ConnCase to exercise the router and plug pipeline.
#
# Note: The CacheRawBody plug caches raw body in endpoint.ex, but ConnCase
# uses build_conn() which goes through the full endpoint pipeline. We need to
# ensure the raw body is available for HMAC verification.

defmodule AssistantWeb.SlackControllerTest do
  # async: false — SlackAuth plug reads Application env at request time; concurrent
  # plug tests that delete/restore :slack_signing_secret cause race conditions.
  use AssistantWeb.ConnCase, async: false
  @moduletag :external

  # Must match the secret in slack_auth_test.exs to avoid async race conditions
  # when both test files run concurrently and share Application env state.
  @signing_secret "test-slack-signing-secret-12345"

  setup do
    prev = Application.get_env(:assistant, :slack_signing_secret)
    Application.put_env(:assistant, :slack_signing_secret, @signing_secret)

    on_exit(fn ->
      if prev do
        Application.put_env(:assistant, :slack_signing_secret, prev)
      else
        Application.delete_env(:assistant, :slack_signing_secret)
      end
    end)

    :ok
  end

  describe "POST /webhooks/slack — url_verification" do
    test "responds with challenge value", %{conn: conn} do
      payload = %{
        "type" => "url_verification",
        "challenge" => "3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P",
        "token" => "placeholder"
      }

      conn = post_slack(conn, payload)

      response = json_response(conn, 200)
      assert response["challenge"] == "3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P"
    end
  end

  describe "POST /webhooks/slack — event_callback" do
    test "returns 200 for valid message event", %{conn: conn} do
      payload = %{
        "type" => "event_callback",
        "event" => %{
          "type" => "message",
          "text" => "Hello from Slack",
          "user" => "U12345",
          "channel" => "C67890",
          "ts" => "1234567890.123456"
        }
      }

      conn = post_slack(conn, payload)

      assert json_response(conn, 200) == %{}
    end

    test "returns 200 for app_mention event", %{conn: conn} do
      payload = %{
        "type" => "event_callback",
        "event" => %{
          "type" => "app_mention",
          "text" => "<@U_BOT> hello",
          "user" => "U12345",
          "channel" => "C67890",
          "ts" => "1234567890.123456"
        }
      }

      conn = post_slack(conn, payload)

      assert json_response(conn, 200) == %{}
    end

    test "returns 200 for bot message (ignored via bot_id)", %{conn: conn} do
      payload = %{
        "type" => "event_callback",
        "event" => %{
          "type" => "message",
          "text" => "I am a bot",
          "bot_id" => "B12345",
          "channel" => "C67890",
          "ts" => "1234567890.123456"
        }
      }

      conn = post_slack(conn, payload)

      assert json_response(conn, 200) == %{}
    end

    test "returns 200 for message with subtype (ignored)", %{conn: conn} do
      payload = %{
        "type" => "event_callback",
        "event" => %{
          "type" => "message",
          "subtype" => "message_changed",
          "channel" => "C67890"
        }
      }

      conn = post_slack(conn, payload)

      assert json_response(conn, 200) == %{}
    end
  end

  describe "POST /webhooks/slack — retry handling" do
    test "returns 200 immediately when X-Slack-Retry-Num is present", %{conn: conn} do
      payload = %{
        "type" => "event_callback",
        "event" => %{
          "type" => "message",
          "text" => "retry message",
          "user" => "U12345",
          "channel" => "C67890",
          "ts" => "1234567890.123456"
        }
      }

      conn = post_slack(conn, payload, extra_headers: [{"x-slack-retry-num", "1"}])

      assert json_response(conn, 200) == %{}
    end
  end

  describe "POST /webhooks/slack — unknown callback type" do
    test "returns 200 for unknown type", %{conn: conn} do
      payload = %{
        "type" => "unknown_type",
        "data" => "something"
      }

      conn = post_slack(conn, payload)

      assert json_response(conn, 200) == %{}
    end
  end

  describe "POST /webhooks/slack without valid auth" do
    test "returns 401 for missing signature", %{conn: conn} do
      payload = %{
        "type" => "event_callback",
        "event" => %{"type" => "message", "text" => "hello"}
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/slack", payload)

      assert json_response(conn, 401)["error"] == "Unauthorized"
    end

    test "returns 401 for wrong signature", %{conn: conn} do
      payload = %{
        "type" => "event_callback",
        "event" => %{"type" => "message", "text" => "hello"}
      }

      body = Jason.encode!(payload)
      timestamp = current_timestamp_str()

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-slack-signature", "v0=wrong_signature_here")
        |> put_req_header("x-slack-request-timestamp", timestamp)
        |> post("/webhooks/slack", body)

      assert json_response(conn, 401)["error"] == "Unauthorized"
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp post_slack(conn, payload, opts \\ []) do
    body = Jason.encode!(payload)
    timestamp = current_timestamp_str()
    signature = compute_signature(timestamp, body)
    extra_headers = Keyword.get(opts, :extra_headers, [])

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-slack-signature", signature)
      |> put_req_header("x-slack-request-timestamp", timestamp)

    conn =
      Enum.reduce(extra_headers, conn, fn {name, value}, acc ->
        put_req_header(acc, name, value)
      end)

    post(conn, "/webhooks/slack", body)
  end

  defp current_timestamp_str do
    to_string(System.system_time(:second))
  end

  defp compute_signature(timestamp, body) do
    basestring = "v0:#{timestamp}:#{body}"

    hmac =
      :crypto.mac(:hmac, :sha256, @signing_secret, basestring)
      |> Base.encode16(case: :lower)

    "v0=#{hmac}"
  end
end

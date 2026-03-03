# test/assistant/integrations/slack/client_test.exs
#
# Bypass-based tests for the Slack Web API HTTP client.
# Verifies request formatting, auth header, response handling,
# and error paths.

defmodule Assistant.Integrations.Slack.ClientTest do
  use ExUnit.Case, async: false

  alias Assistant.Integrations.Slack.Client

  @bot_token "xoxb-test-token-12345"

  setup do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"

    prev_url = Application.get_env(:assistant, :slack_api_base_url)
    Application.put_env(:assistant, :slack_api_base_url, base_url)

    on_exit(fn ->
      if prev_url,
        do: Application.put_env(:assistant, :slack_api_base_url, prev_url),
        else: Application.delete_env(:assistant, :slack_api_base_url)
    end)

    %{bypass: bypass}
  end

  # ---------------------------------------------------------------
  # post_message/4
  # ---------------------------------------------------------------

  describe "post_message/4" do
    test "sends correctly formatted request with auth header", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/chat.postMessage", fn conn ->
        # Verify auth header
        [auth_header] = Plug.Conn.get_req_header(conn, "authorization")
        assert auth_header == "Bearer #{@bot_token}"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["channel"] == "C12345"
        assert decoded["text"] == "Hello Slack!"
        refute Map.has_key?(decoded, "thread_ts")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"ok" => true, "channel" => "C12345", "ts" => "1234567890.123456"})
        )
      end)

      assert {:ok, %{"ok" => true, "channel" => "C12345"}} =
               Client.post_message(@bot_token, "C12345", "Hello Slack!")
    end

    test "includes thread_ts for threaded replies", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/chat.postMessage", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["thread_ts"] == "1234567890.000001"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "ts" => "1234567890.999999"}))
      end)

      assert {:ok, _} =
               Client.post_message(@bot_token, "C12345", "Reply!", thread_ts: "1234567890.000001")
    end

    test "returns error for Slack API error response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/chat.postMessage", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => false, "error" => "channel_not_found"}))
      end)

      assert {:error, {:api_error, "channel_not_found"}} =
               Client.post_message(@bot_token, "C_INVALID", "Hello!")
    end

    test "returns error for rate limiting", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/chat.postMessage", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => false, "error" => "ratelimited"}))
      end)

      assert {:error, {:api_error, "ratelimited"}} =
               Client.post_message(@bot_token, "C12345", "Hello!")
    end
  end

  # ---------------------------------------------------------------
  # post_ephemeral/4
  # ---------------------------------------------------------------

  describe "post_ephemeral/4" do
    test "sends ephemeral message with user field", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/chat.postEphemeral", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["channel"] == "C12345"
        assert decoded["user"] == "U99999"
        assert decoded["text"] == "Only you can see this"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "message_ts" => "1234.5678"}))
      end)

      assert {:ok, _} =
               Client.post_ephemeral(@bot_token, "C12345", "U99999", "Only you can see this")
    end
  end

  # ---------------------------------------------------------------
  # auth_test/1
  # ---------------------------------------------------------------

  describe "auth_test/1" do
    test "returns bot identity info", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/auth.test", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "ok" => true,
            "url" => "https://myteam.slack.com/",
            "team" => "My Team",
            "user" => "bot",
            "team_id" => "T12345",
            "user_id" => "U12345"
          })
        )
      end)

      assert {:ok, %{"ok" => true, "team_id" => "T12345"}} = Client.auth_test(@bot_token)
    end
  end

  # ---------------------------------------------------------------
  # conversations_info/2
  # ---------------------------------------------------------------

  describe "conversations_info/2" do
    test "returns channel info", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/conversations.info", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["channel"] == "C12345"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "ok" => true,
            "channel" => %{"id" => "C12345", "name" => "general"}
          })
        )
      end)

      assert {:ok, %{"ok" => true, "channel" => %{"name" => "general"}}} =
               Client.conversations_info(@bot_token, "C12345")
    end
  end

  # ---------------------------------------------------------------
  # Error cases
  # ---------------------------------------------------------------

  describe "error handling" do
    test "handles network errors (connection refused)", %{bypass: bypass} do
      Bypass.down(bypass)

      assert {:error, {:request_failed, _}} =
               Client.post_message(@bot_token, "C12345", "Hello!")
    end

    test "handles non-200 HTTP errors", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/chat.postMessage", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"error" => "internal_error"}))
      end)

      assert {:error, {:http_error, 500, _}} =
               Client.post_message(@bot_token, "C12345", "Hello!")
    end
  end
end

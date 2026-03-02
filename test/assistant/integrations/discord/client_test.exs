# test/assistant/integrations/discord/client_test.exs
#
# Bypass-based tests for the Discord Bot API HTTP client.
# Verifies request formatting, response handling, error paths,
# and message truncation.

defmodule Assistant.Integrations.Discord.ClientTest do
  use ExUnit.Case, async: false

  alias Assistant.Integrations.Discord.Client

  @bot_token "test-discord-bot-token-12345"

  setup do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"

    prev_token = Application.get_env(:assistant, :discord_bot_token)
    prev_url = Application.get_env(:assistant, :discord_api_base_url)

    Application.put_env(:assistant, :discord_bot_token, @bot_token)
    Application.put_env(:assistant, :discord_api_base_url, base_url)

    on_exit(fn ->
      if prev_token,
        do: Application.put_env(:assistant, :discord_bot_token, prev_token),
        else: Application.delete_env(:assistant, :discord_bot_token)

      if prev_url,
        do: Application.put_env(:assistant, :discord_api_base_url, prev_url),
        else: Application.delete_env(:assistant, :discord_api_base_url)
    end)

    %{bypass: bypass}
  end

  # ---------------------------------------------------------------
  # send_message/3
  # ---------------------------------------------------------------

  describe "send_message/3" do
    test "sends correctly formatted request", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/channels/123456/messages", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bot #{@bot_token}"]

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["content"] == "Hello Discord!"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"id" => "msg1", "content" => "Hello Discord!"}))
      end)

      assert {:ok, %{"id" => "msg1"}} = Client.send_message("123456", "Hello Discord!")
    end

    test "sends to thread channel when thread_id provided", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/channels/thread789/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["content"] == "Thread reply"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"id" => "msg2"}))
      end)

      assert {:ok, _} = Client.send_message("123456", "Thread reply", thread_id: "thread789")
    end

    test "returns error for API error response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/channels/123456/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(403, Jason.encode!(%{"message" => "Missing Permissions", "code" => 50013}))
      end)

      assert {:error, {:api_error, 403, "Missing Permissions"}} =
               Client.send_message("123456", "Hello!")
    end

    test "returns error for rate limiting (429)", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/channels/123456/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, Jason.encode!(%{"message" => "You are being rate limited.", "retry_after" => 1.5}))
      end)

      assert {:error, {:api_error, 429, "You are being rate limited."}} =
               Client.send_message("123456", "Hello!")
    end

    test "truncates messages exceeding 2000 char limit", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/channels/123456/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert String.ends_with?(decoded["content"], "[Message truncated]")
        assert String.length(decoded["content"]) <= 2000

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"id" => "msg3"}))
      end)

      long_message = String.duplicate("x", 3000)
      assert {:ok, _} = Client.send_message("123456", long_message)
    end

    test "does not truncate messages within limit", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/channels/123456/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["content"] == "short"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"id" => "msg4"}))
      end)

      assert {:ok, _} = Client.send_message("123456", "short")
    end
  end

  # ---------------------------------------------------------------
  # trigger_typing/1
  # ---------------------------------------------------------------

  describe "trigger_typing/1" do
    test "sends typing indicator", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/channels/123456/typing", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bot #{@bot_token}"]

        conn
        |> Plug.Conn.resp(204, "")
      end)

      assert {:ok, _} = Client.trigger_typing("123456")
    end
  end

  # ---------------------------------------------------------------
  # get_gateway/0
  # ---------------------------------------------------------------

  describe "get_gateway/0" do
    test "returns gateway URL on success", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/gateway", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"url" => "wss://gateway.discord.gg"}))
      end)

      assert {:ok, %{"url" => "wss://gateway.discord.gg"}} = Client.get_gateway()
    end
  end

  # ---------------------------------------------------------------
  # Error cases
  # ---------------------------------------------------------------

  describe "error handling" do
    test "returns error when token is not configured" do
      Application.delete_env(:assistant, :discord_bot_token)

      assert {:error, :token_not_configured} = Client.send_message("123456", "Hello!")
    end

    test "handles network errors (connection refused)", %{bypass: bypass} do
      Bypass.down(bypass)

      assert {:error, {:request_failed, _}} = Client.send_message("123456", "Hello!")
    end

    test "handles unexpected response format", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/channels/123456/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"message" => "Internal Server Error"}))
      end)

      assert {:error, {:api_error, 500, "Internal Server Error"}} =
               Client.send_message("123456", "Hello!")
    end
  end
end

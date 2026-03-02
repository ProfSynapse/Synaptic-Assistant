# test/assistant/integrations/telegram/client_test.exs
#
# Bypass-based tests for the Telegram Bot API HTTP client.
# Verifies request formatting, response handling, error paths,
# and message truncation.

defmodule Assistant.Integrations.Telegram.ClientTest do
  use ExUnit.Case, async: false

  alias Assistant.Integrations.Telegram.Client

  @bot_token "test-bot-token-12345"

  setup do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"

    prev_token = Application.get_env(:assistant, :telegram_bot_token)
    prev_url = Application.get_env(:assistant, :telegram_api_base_url)

    Application.put_env(:assistant, :telegram_bot_token, @bot_token)
    Application.put_env(:assistant, :telegram_api_base_url, base_url)

    on_exit(fn ->
      if prev_token,
        do: Application.put_env(:assistant, :telegram_bot_token, prev_token),
        else: Application.delete_env(:assistant, :telegram_bot_token)

      if prev_url,
        do: Application.put_env(:assistant, :telegram_api_base_url, prev_url),
        else: Application.delete_env(:assistant, :telegram_api_base_url)
    end)

    %{bypass: bypass}
  end

  # ---------------------------------------------------------------
  # send_message/3
  # ---------------------------------------------------------------

  describe "send_message/3" do
    test "sends correctly formatted request", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/bot#{@bot_token}/sendMessage", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["chat_id"] == "12345"
        assert decoded["text"] == "Hello!"
        assert decoded["parse_mode"] == "Markdown"
        refute Map.has_key?(decoded, "reply_to_message_id")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 1}}))
      end)

      assert {:ok, %{"message_id" => 1}} = Client.send_message("12345", "Hello!")
    end

    test "includes reply_to_message_id when provided", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/bot#{@bot_token}/sendMessage", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["reply_to_message_id"] == 42

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 2}}))
      end)

      assert {:ok, _} = Client.send_message("12345", "Reply!", reply_to_message_id: 42)
    end

    test "returns error for API error response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/bot#{@bot_token}/sendMessage", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, Jason.encode!(%{"ok" => false, "description" => "Bad Request: chat not found"}))
      end)

      assert {:error, {:api_error, 400, "Bad Request: chat not found"}} =
               Client.send_message("invalid", "Hello!")
    end

    test "returns error for rate limiting (429)", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/bot#{@bot_token}/sendMessage", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, Jason.encode!(%{"ok" => false, "description" => "Too Many Requests: retry after 30"}))
      end)

      assert {:error, {:api_error, 429, "Too Many Requests: retry after 30"}} =
               Client.send_message("12345", "Hello!")
    end

    test "truncates messages exceeding max length", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/bot#{@bot_token}/sendMessage", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Message should be truncated and have the truncation suffix
        assert String.ends_with?(decoded["text"], "[Message truncated]")
        assert String.length(decoded["text"]) <= 4096

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 3}}))
      end)

      long_message = String.duplicate("x", 5000)
      assert {:ok, _} = Client.send_message("12345", long_message)
    end

    test "does not truncate messages within limit", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/bot#{@bot_token}/sendMessage", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["text"] == "short"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 4}}))
      end)

      assert {:ok, _} = Client.send_message("12345", "short")
    end
  end

  # ---------------------------------------------------------------
  # send_chat_action/2
  # ---------------------------------------------------------------

  describe "send_chat_action/2" do
    test "sends typing action", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/bot#{@bot_token}/sendChatAction", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["chat_id"] == "12345"
        assert decoded["action"] == "typing"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => true}))
      end)

      assert {:ok, true} = Client.send_chat_action("12345", "typing")
    end
  end

  # ---------------------------------------------------------------
  # get_me/0
  # ---------------------------------------------------------------

  describe "get_me/0" do
    test "returns bot info on success", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/bot#{@bot_token}/getMe", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => %{"id" => 123, "is_bot" => true, "first_name" => "TestBot"}
        }))
      end)

      assert {:ok, %{"id" => 123, "is_bot" => true}} = Client.get_me()
    end
  end

  # ---------------------------------------------------------------
  # set_webhook/2
  # ---------------------------------------------------------------

  describe "set_webhook/2" do
    test "sends webhook URL with optional secret_token", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/bot#{@bot_token}/setWebhook", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["url"] == "https://example.com/webhook"
        assert decoded["secret_token"] == "my-secret"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => true}))
      end)

      assert {:ok, true} = Client.set_webhook("https://example.com/webhook", secret_token: "my-secret")
    end
  end

  # ---------------------------------------------------------------
  # Error cases
  # ---------------------------------------------------------------

  describe "error handling" do
    test "returns error when token is not configured" do
      Application.delete_env(:assistant, :telegram_bot_token)

      assert {:error, :token_not_configured} = Client.send_message("12345", "Hello!")
    end

    test "handles network errors (connection refused)", %{bypass: bypass} do
      Bypass.down(bypass)

      assert {:error, {:request_failed, _}} = Client.send_message("12345", "Hello!")
    end

    test "handles unexpected response format", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/bot#{@bot_token}/sendMessage", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"error" => "internal"}))
      end)

      assert {:error, {:api_error, 500, _}} = Client.send_message("12345", "Hello!")
    end
  end
end

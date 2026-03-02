# test/assistant_web/plugs/telegram_auth_test.exs
#
# Tests for the TelegramAuth plug that verifies Telegram webhook secret tokens.
# Uses Plug.Test.conn/3 to create test connections with custom headers.

defmodule AssistantWeb.Plugs.TelegramAuthTest do
  # async: false — tests modify Application env for :telegram_webhook_secret;
  # concurrent controller tests reading the same key causes race conditions.
  use ExUnit.Case, async: false

  alias AssistantWeb.Plugs.TelegramAuth

  @secret "test-telegram-secret-token"

  setup do
    prev = Application.get_env(:assistant, :telegram_webhook_secret)
    Application.put_env(:assistant, :telegram_webhook_secret, @secret)

    on_exit(fn ->
      if prev do
        Application.put_env(:assistant, :telegram_webhook_secret, prev)
      else
        Application.delete_env(:assistant, :telegram_webhook_secret)
      end
    end)

    :ok
  end

  describe "call/2 with valid secret" do
    test "passes through and assigns :telegram_verified" do
      conn =
        :post
        |> Plug.Test.conn("/webhooks/telegram", "")
        |> put_secret_header(@secret)
        |> TelegramAuth.call([])

      assert conn.assigns[:telegram_verified] == true
      refute conn.halted
    end
  end

  describe "call/2 with invalid credentials" do
    test "returns 401 for missing header" do
      conn =
        :post
        |> Plug.Test.conn("/webhooks/telegram", "")
        |> TelegramAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end

    test "returns 401 for wrong token" do
      conn =
        :post
        |> Plug.Test.conn("/webhooks/telegram", "")
        |> put_secret_header("wrong-secret")
        |> TelegramAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end

    test "returns 401 for empty token" do
      conn =
        :post
        |> Plug.Test.conn("/webhooks/telegram", "")
        |> put_secret_header("")
        |> TelegramAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end
  end

  describe "call/2 with no configured secret (fail-closed)" do
    test "returns 401 when telegram_webhook_secret is nil" do
      Application.delete_env(:assistant, :telegram_webhook_secret)

      conn =
        :post
        |> Plug.Test.conn("/webhooks/telegram", "")
        |> put_secret_header("any-token")
        |> TelegramAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp put_secret_header(conn, token) do
    Plug.Conn.put_req_header(conn, "x-telegram-bot-api-secret-token", token)
  end
end

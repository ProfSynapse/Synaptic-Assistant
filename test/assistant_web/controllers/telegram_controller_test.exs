# test/assistant_web/controllers/telegram_controller_test.exs
#
# Integration tests for the Telegram webhook controller.
# Tests the full request pipeline: TelegramAuth plug → controller → response.
# Uses ConnCase to exercise the router and plug pipeline.

defmodule AssistantWeb.TelegramControllerTest do
  # async: false — TelegramAuth plug reads Application env at request time; concurrent
  # plug tests that delete/restore :telegram_webhook_secret cause race conditions.
  use AssistantWeb.ConnCase, async: false

  # Must match the secret in telegram_auth_test.exs to avoid async race conditions
  # when both test files run concurrently and share Application env state.
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

  describe "POST /webhooks/telegram with valid auth" do
    test "returns 200 for text message", %{conn: conn} do
      payload = %{
        "message" => %{
          "message_id" => 100,
          "text" => "Hello bot",
          "date" => 1_709_395_200,
          "chat" => %{"id" => 67890, "type" => "private"},
          "from" => %{"id" => 12345, "first_name" => "Jane"}
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-telegram-bot-api-secret-token", @secret)
        |> post("/webhooks/telegram", payload)

      assert json_response(conn, 200) == %{}
    end

    test "returns 200 for non-text update (ignored)", %{conn: conn} do
      payload = %{
        "edited_message" => %{
          "message_id" => 200,
          "text" => "edited text",
          "chat" => %{"id" => 67890}
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-telegram-bot-api-secret-token", @secret)
        |> post("/webhooks/telegram", payload)

      assert json_response(conn, 200) == %{}
    end

    test "returns 200 for callback_query (ignored)", %{conn: conn} do
      payload = %{
        "callback_query" => %{
          "id" => "abc123",
          "data" => "button_click"
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-telegram-bot-api-secret-token", @secret)
        |> post("/webhooks/telegram", payload)

      assert json_response(conn, 200) == %{}
    end
  end

  describe "POST /webhooks/telegram without auth" do
    test "returns 401 for missing auth header", %{conn: conn} do
      payload = %{
        "message" => %{
          "message_id" => 100,
          "text" => "Hello",
          "chat" => %{"id" => 67890},
          "from" => %{"id" => 12345}
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/telegram", payload)

      assert json_response(conn, 401)["error"] == "Unauthorized"
    end

    test "returns 401 for wrong secret", %{conn: conn} do
      payload = %{
        "message" => %{
          "message_id" => 100,
          "text" => "Hello",
          "chat" => %{"id" => 67890},
          "from" => %{"id" => 12345}
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-telegram-bot-api-secret-token", "wrong-secret")
        |> post("/webhooks/telegram", payload)

      assert json_response(conn, 401)["error"] == "Unauthorized"
    end
  end
end

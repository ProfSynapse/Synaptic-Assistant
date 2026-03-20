# test/assistant_web/controllers/telegram_controller_test.exs
#
# Integration tests for the Telegram webhook controller.
# Tests the full request pipeline: TelegramAuth plug → controller → response.
# Uses ConnCase to exercise the router and plug pipeline.

defmodule AssistantWeb.TelegramControllerTest do
  # async: false — TelegramAuth plug reads Application env at request time; concurrent
  # plug tests that delete/restore :telegram_webhook_secret cause race conditions.
  use AssistantWeb.ConnCase, async: false
  @moduletag :external

  alias Assistant.IntegrationSettings.Cache
  alias Assistant.Repo
  alias Assistant.Schemas.{AuthToken, User, UserIdentity}

  # Must match the secret in telegram_auth_test.exs to avoid async race conditions
  # when both test files run concurrently and share Application env state.
  @secret "test-telegram-secret-token"
  @bot_token "telegram-controller-test-token"

  setup do
    prev = Application.get_env(:assistant, :telegram_webhook_secret)
    prev_token = Application.get_env(:assistant, :telegram_bot_token)
    prev_base_url = Application.get_env(:assistant, :telegram_api_base_url)
    bypass = Bypass.open()

    Application.put_env(:assistant, :telegram_webhook_secret, @secret)
    Application.put_env(:assistant, :telegram_bot_token, @bot_token)
    Application.put_env(:assistant, :telegram_api_base_url, "http://localhost:#{bypass.port}")
    Cache.invalidate(:telegram_bot_token)

    on_exit(fn ->
      Cache.invalidate(:telegram_bot_token)

      if prev do
        Application.put_env(:assistant, :telegram_webhook_secret, prev)
      else
        Application.delete_env(:assistant, :telegram_webhook_secret)
      end

      if prev_token do
        Application.put_env(:assistant, :telegram_bot_token, prev_token)
      else
        Application.delete_env(:assistant, :telegram_bot_token)
      end

      if prev_base_url do
        Application.put_env(:assistant, :telegram_api_base_url, prev_base_url)
      else
        Application.delete_env(:assistant, :telegram_api_base_url)
      end
    end)

    %{bypass: bypass}
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

    test "ignores unlinked Telegram users without auto-creating identities", %{conn: conn} do
      payload = %{
        "message" => %{
          "message_id" => 110,
          "text" => "Hello bot",
          "date" => 1_709_395_200,
          "chat" => %{"id" => 998_877, "type" => "private"},
          "from" => %{"id" => 998_877, "first_name" => "Stranger"}
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-telegram-bot-api-secret-token", @secret)
        |> post("/webhooks/telegram", payload)

      assert json_response(conn, 200) == %{}

      refute Repo.get_by(UserIdentity,
               channel: "telegram",
               external_id: "998877",
               space_id: "998877"
             )
    end

    test "consumes a /start token and links the Telegram identity", %{conn: conn, bypass: bypass} do
      user = insert_user("telegram-link")
      raw_token = "telegram-link-token-#{System.unique_integer([:positive])}"
      insert_auth_token(user.id, raw_token, "telegram_connect")

      Bypass.expect_once(bypass, "POST", "/bot#{@bot_token}/sendMessage", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["chat_id"] == "12345"
        assert decoded["text"] =~ "Telegram connected"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 1}}))
      end)

      payload = %{
        "message" => %{
          "message_id" => 120,
          "text" => "/start #{raw_token}",
          "date" => 1_709_395_200,
          "chat" => %{"id" => 12345, "type" => "private"},
          "from" => %{"id" => 12345, "first_name" => "Jane"}
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-telegram-bot-api-secret-token", @secret)
        |> post("/webhooks/telegram", payload)

      assert json_response(conn, 200) == %{}

      assert %UserIdentity{} =
               identity =
               Repo.get_by(UserIdentity,
                 user_id: user.id,
                 channel: "telegram",
                 external_id: "12345"
               )

      assert identity.space_id == "12345"
      assert identity.display_name == "Jane"
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

  defp insert_user(prefix) do
    %User{}
    |> User.changeset(%{
      external_id: "#{prefix}-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Repo.insert!()
  end

  defp insert_auth_token(user_id, raw_token, purpose) do
    token_hash =
      :crypto.hash(:sha256, raw_token)
      |> Base.url_encode64(padding: false)

    %AuthToken{}
    |> AuthToken.changeset(%{
      user_id: user_id,
      token_hash: token_hash,
      purpose: purpose,
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
    })
    |> Repo.insert!()
  end
end

# test/assistant_web/controllers/discord_controller_test.exs
#
# Integration tests for the Discord interaction webhook controller.
# Tests the full request pipeline: DiscordAuth plug -> controller -> response.
# Uses ConnCase to exercise the router and plug pipeline.

defmodule AssistantWeb.DiscordControllerTest do
  # async: false — DiscordAuth plug reads Application env at request time; concurrent
  # plug tests that delete/restore :discord_public_key cause race conditions.
  use AssistantWeb.ConnCase, async: false
  @moduletag :external

  # Generate a test Ed25519 keypair for signing test payloads.
  @private_key_raw :crypto.strong_rand_bytes(32)
  @public_key_raw elem(:crypto.generate_key(:eddsa, :ed25519, @private_key_raw), 0)
  @public_key_hex Base.encode16(@public_key_raw, case: :lower)

  setup do
    prev = Application.get_env(:assistant, :discord_public_key)
    Application.put_env(:assistant, :discord_public_key, @public_key_hex)

    on_exit(fn ->
      if prev do
        Application.put_env(:assistant, :discord_public_key, prev)
      else
        Application.delete_env(:assistant, :discord_public_key)
      end
    end)

    :ok
  end

  describe "POST /webhooks/discord — PING" do
    test "responds with PONG (type 1)", %{conn: conn} do
      payload = %{"type" => 1}
      conn = post_discord(conn, payload)

      assert json_response(conn, 200) == %{"type" => 1}
    end
  end

  describe "POST /webhooks/discord — APPLICATION_COMMAND" do
    test "returns deferred response (type 5) for slash command", %{conn: conn} do
      payload = %{
        "type" => 2,
        "id" => "1234567890123456789",
        "guild_id" => "111222333",
        "channel_id" => "444555666",
        "member" => %{
          "nick" => "TestNick",
          "user" => %{
            "id" => "777888999",
            "username" => "testuser",
            "bot" => false
          }
        },
        "data" => %{
          "id" => "cmd123",
          "name" => "ask",
          "options" => [
            %{"name" => "query", "type" => 3, "value" => "hello"}
          ]
        }
      }

      conn = post_discord(conn, payload)

      assert json_response(conn, 200) == %{"type" => 5}
    end

    test "returns deferred response for bot interaction (ignored)", %{conn: conn} do
      payload = %{
        "type" => 2,
        "id" => "1234567890123456789",
        "guild_id" => "111222333",
        "channel_id" => "444555666",
        "member" => %{
          "user" => %{
            "id" => "777888999",
            "username" => "botuser",
            "bot" => true
          }
        },
        "data" => %{
          "name" => "ask"
        }
      }

      conn = post_discord(conn, payload)

      assert json_response(conn, 200) == %{"type" => 5}
    end
  end

  describe "POST /webhooks/discord — unknown type" do
    test "returns deferred response for unknown interaction type", %{conn: conn} do
      payload = %{"type" => 99, "id" => "123"}
      conn = post_discord(conn, payload)

      assert json_response(conn, 200) == %{"type" => 5}
    end
  end

  describe "POST /webhooks/discord without valid auth" do
    test "returns 401 for missing signature headers", %{conn: conn} do
      payload = %{"type" => 1}

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/discord", payload)

      assert json_response(conn, 401)["error"] == "Unauthorized"
    end

    test "returns 401 for wrong signature", %{conn: conn} do
      payload = %{"type" => 1}
      body = Jason.encode!(payload)
      timestamp = to_string(System.system_time(:second))
      fake_sig = String.duplicate("ab", 64)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-signature-ed25519", fake_sig)
        |> put_req_header("x-signature-timestamp", timestamp)
        |> post("/webhooks/discord", body)

      assert json_response(conn, 401)["error"] == "Unauthorized"
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp post_discord(conn, payload) do
    body = Jason.encode!(payload)
    timestamp = to_string(System.system_time(:second))
    signature = sign_message(timestamp, body)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-signature-ed25519", signature)
    |> put_req_header("x-signature-timestamp", timestamp)
    |> post("/webhooks/discord", body)
  end

  defp sign_message(timestamp, body) do
    message = timestamp <> body
    signature = :crypto.sign(:eddsa, :none, message, [@private_key_raw, :ed25519])
    Base.encode16(signature, case: :lower)
  end
end

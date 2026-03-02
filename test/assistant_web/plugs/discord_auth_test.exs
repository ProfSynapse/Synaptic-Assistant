# test/assistant_web/plugs/discord_auth_test.exs
#
# Tests for the DiscordAuth plug that verifies Discord Ed25519 request signatures.
# Generates a test Ed25519 keypair and computes signatures for verification.

defmodule AssistantWeb.Plugs.DiscordAuthTest do
  # async: false — tests modify Application env for :discord_public_key;
  # concurrent controller tests reading the same key causes race conditions.
  use ExUnit.Case, async: false

  alias AssistantWeb.Plugs.DiscordAuth

  # Generate a test Ed25519 keypair at compile time.
  # We use Erlang's :crypto to generate a keypair for signing test payloads.
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

  describe "call/2 with valid signature" do
    test "passes through and assigns :discord_verified" do
      body = ~s({"type":1})
      timestamp = "1709395200"
      signature = sign_message(timestamp, body)

      conn =
        :post
        |> Plug.Test.conn("/webhooks/discord", body)
        |> put_raw_body(body)
        |> put_discord_headers(signature, timestamp)
        |> DiscordAuth.call([])

      assert conn.assigns[:discord_verified] == true
      refute conn.halted
    end
  end

  describe "call/2 with missing headers" do
    test "returns 401 for missing signature header" do
      body = ~s({"type":2})
      timestamp = "1709395200"

      conn =
        :post
        |> Plug.Test.conn("/webhooks/discord", body)
        |> put_raw_body(body)
        |> Plug.Conn.put_req_header("x-signature-timestamp", timestamp)
        |> DiscordAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end

    test "returns 401 for missing timestamp header" do
      body = ~s({"type":2})
      signature = sign_message("1709395200", body)

      conn =
        :post
        |> Plug.Test.conn("/webhooks/discord", body)
        |> put_raw_body(body)
        |> Plug.Conn.put_req_header("x-signature-ed25519", signature)
        |> DiscordAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end
  end

  describe "call/2 with invalid signature" do
    test "returns 401 for wrong signature" do
      body = ~s({"type":2})
      timestamp = "1709395200"
      # Fake signature (valid hex but wrong value)
      fake_sig = String.duplicate("ab", 64)

      conn =
        :post
        |> Plug.Test.conn("/webhooks/discord", body)
        |> put_raw_body(body)
        |> put_discord_headers(fake_sig, timestamp)
        |> DiscordAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end

    test "returns 401 for tampered body" do
      original_body = ~s({"type":2})
      tampered_body = ~s({"type":999})
      timestamp = "1709395200"
      # Signature was computed against original body
      signature = sign_message(timestamp, original_body)

      conn =
        :post
        |> Plug.Test.conn("/webhooks/discord", tampered_body)
        |> put_raw_body(tampered_body)
        |> put_discord_headers(signature, timestamp)
        |> DiscordAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end

    test "returns 401 for non-hex signature format" do
      body = ~s({"type":1})
      timestamp = "1709395200"

      conn =
        :post
        |> Plug.Test.conn("/webhooks/discord", body)
        |> put_raw_body(body)
        |> put_discord_headers("not-valid-hex!", timestamp)
        |> DiscordAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end
  end

  describe "call/2 with no configured public key (fail-closed)" do
    test "returns 401 when discord_public_key is nil" do
      Application.delete_env(:assistant, :discord_public_key)

      body = ~s({"type":1})
      timestamp = "1709395200"

      conn =
        :post
        |> Plug.Test.conn("/webhooks/discord", body)
        |> put_raw_body(body)
        |> put_discord_headers("aabbccdd", timestamp)
        |> DiscordAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end
  end

  describe "call/2 with missing raw body" do
    test "returns 401 when raw_body is not cached" do
      body = ~s({"type":1})
      timestamp = "1709395200"
      signature = sign_message(timestamp, body)

      conn =
        :post
        |> Plug.Test.conn("/webhooks/discord", body)
        # Intentionally not setting raw_body in private
        |> put_discord_headers(signature, timestamp)
        |> DiscordAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp sign_message(timestamp, body) do
    message = timestamp <> body
    signature = :crypto.sign(:eddsa, :none, message, [@private_key_raw, :ed25519])
    Base.encode16(signature, case: :lower)
  end

  defp put_raw_body(conn, body) do
    Plug.Conn.put_private(conn, :raw_body, body)
  end

  defp put_discord_headers(conn, signature, timestamp) do
    conn
    |> Plug.Conn.put_req_header("x-signature-ed25519", signature)
    |> Plug.Conn.put_req_header("x-signature-timestamp", timestamp)
  end
end

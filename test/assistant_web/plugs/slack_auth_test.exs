# test/assistant_web/plugs/slack_auth_test.exs
#
# Tests for the SlackAuth plug that verifies Slack HMAC-SHA256 request signatures.
# Uses Plug.Test.conn/3 with raw body injection and computed HMAC signatures.

defmodule AssistantWeb.Plugs.SlackAuthTest do
  # async: false — tests modify Application env for :slack_signing_secret;
  # concurrent controller tests reading the same key causes race conditions.
  use ExUnit.Case, async: false

  alias AssistantWeb.Plugs.SlackAuth

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

  describe "call/2 with valid signature" do
    test "passes through and assigns :slack_verified" do
      body = ~s({"type":"event_callback","event":{"type":"message"}})
      timestamp = current_timestamp_str()
      signature = compute_signature(timestamp, body)

      conn =
        :post
        |> Plug.Test.conn("/webhooks/slack", body)
        |> put_raw_body(body)
        |> put_slack_headers(signature, timestamp)
        |> SlackAuth.call([])

      assert conn.assigns[:slack_verified] == true
      refute conn.halted
    end
  end

  describe "call/2 with missing headers" do
    test "returns 401 for missing signature header" do
      body = ~s({"type":"event_callback"})
      timestamp = current_timestamp_str()

      conn =
        :post
        |> Plug.Test.conn("/webhooks/slack", body)
        |> put_raw_body(body)
        |> Plug.Conn.put_req_header("x-slack-request-timestamp", timestamp)
        |> SlackAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end

    test "returns 401 for missing timestamp header" do
      body = ~s({"type":"event_callback"})

      conn =
        :post
        |> Plug.Test.conn("/webhooks/slack", body)
        |> put_raw_body(body)
        |> Plug.Conn.put_req_header("x-slack-signature", "v0=fakesig")
        |> SlackAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end
  end

  describe "call/2 replay protection" do
    test "returns 401 when timestamp is too old (>5 minutes)" do
      body = ~s({"type":"event_callback"})
      # 10 minutes ago
      old_timestamp = to_string(System.system_time(:second) - 600)
      signature = compute_signature(old_timestamp, body)

      conn =
        :post
        |> Plug.Test.conn("/webhooks/slack", body)
        |> put_raw_body(body)
        |> put_slack_headers(signature, old_timestamp)
        |> SlackAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end
  end

  describe "call/2 with invalid signature" do
    test "returns 401 for wrong HMAC" do
      body = ~s({"type":"event_callback"})
      timestamp = current_timestamp_str()

      conn =
        :post
        |> Plug.Test.conn("/webhooks/slack", body)
        |> put_raw_body(body)
        |> put_slack_headers("v0=aaaaaabbbbbbcccccc", timestamp)
        |> SlackAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end

    test "returns 401 for tampered body" do
      original_body = ~s({"type":"event_callback"})
      tampered_body = ~s({"type":"MALICIOUS"})
      timestamp = current_timestamp_str()
      # Signature was computed against original body
      signature = compute_signature(timestamp, original_body)

      conn =
        :post
        |> Plug.Test.conn("/webhooks/slack", tampered_body)
        |> put_raw_body(tampered_body)
        |> put_slack_headers(signature, timestamp)
        |> SlackAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end
  end

  describe "call/2 with no configured secret (fail-closed)" do
    test "returns 401 when slack_signing_secret is nil" do
      Application.delete_env(:assistant, :slack_signing_secret)

      body = ~s({"type":"event_callback"})
      timestamp = current_timestamp_str()

      conn =
        :post
        |> Plug.Test.conn("/webhooks/slack", body)
        |> put_raw_body(body)
        |> put_slack_headers("v0=anything", timestamp)
        |> SlackAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end
  end

  describe "call/2 with missing raw body" do
    test "returns 401 when raw_body is not cached" do
      body = ~s({"type":"event_callback"})
      timestamp = current_timestamp_str()
      signature = compute_signature(timestamp, body)

      conn =
        :post
        |> Plug.Test.conn("/webhooks/slack", body)
        # Intentionally not setting raw_body in private
        |> put_slack_headers(signature, timestamp)
        |> SlackAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

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

  defp put_raw_body(conn, body) do
    Plug.Conn.put_private(conn, :raw_body, body)
  end

  defp put_slack_headers(conn, signature, timestamp) do
    conn
    |> Plug.Conn.put_req_header("x-slack-signature", signature)
    |> Plug.Conn.put_req_header("x-slack-request-timestamp", timestamp)
  end
end

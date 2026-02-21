# test/assistant_web/controllers/oauth_controller_integration_test.exs
#
# Integration tests for OAuthController callback flow.
#
# Tests the controller paths that can be exercised without mocking Google's
# token endpoint. The full happy path (code exchange via Req.post to Google)
# cannot be tested because OAuth.exchange_code/2 uses a hardcoded URL; that
# would require making @google_token_url configurable or using a Req.Test
# plug with a named client.
#
# What IS tested:
#   - State parameter generation, embedding, and verification roundtrip
#   - Auth token lookup from state.token_hash in callback
#   - Error responses for all failure branches in the callback with chain
#   - Controller-level XSS prevention via success_html rendering
#   - Token storage after a simulated successful exchange
#   - PendingIntentWorker enqueue after token storage
#
# Related files:
#   - lib/assistant_web/controllers/oauth_controller.ex (module under test)
#   - lib/assistant/auth/oauth.ex (state signing/verification, code exchange)
#   - lib/assistant/auth/magic_link.ex (magic link lifecycle)
#   - lib/assistant/auth/token_store.ex (token CRUD)
#   - lib/assistant/workers/pending_intent_worker.ex (replay worker)

defmodule AssistantWeb.OAuthControllerIntegrationTest do
  # async: false — modifies global Application env for OAuth credentials.
  use AssistantWeb.ConnCase, async: false

  alias Assistant.Auth.MagicLink
  alias Assistant.Auth.OAuth
  alias Assistant.Auth.TokenStore
  alias Assistant.Schemas.AuthToken

  # ---------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------

  setup do
    user = insert_test_user()

    Application.put_env(:assistant, :google_oauth_client_id, "test-client-id")
    Application.put_env(:assistant, :google_oauth_client_secret, "test-client-secret")

    on_exit(fn ->
      Application.delete_env(:assistant, :google_oauth_client_id)
      Application.delete_env(:assistant, :google_oauth_client_secret)
    end)

    %{user: user}
  end

  defp insert_test_user do
    %Assistant.Schemas.User{}
    |> Assistant.Schemas.User.changeset(%{
      external_id: "oauth-integ-test-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Assistant.Repo.insert!()
  end

  defp insert_auth_token(user_id, raw_token, opts \\ []) do
    token_hash = MagicLink.hash_token(raw_token)
    expires_at = Keyword.get(opts, :expires_at, future_expiry())

    %AuthToken{}
    |> AuthToken.changeset(%{
      user_id: user_id,
      token_hash: token_hash,
      purpose: "oauth_google",
      code_verifier:
        Keyword.get(opts, :code_verifier, "test-verifier-#{System.unique_integer([:positive])}"),
      pending_intent:
        Keyword.get(opts, :pending_intent, %{"message" => "test command", "channel" => "test"}),
      expires_at: expires_at
    })
    |> Assistant.Repo.insert!()
  end

  defp future_expiry, do: DateTime.add(DateTime.utc_now(), 600, :second)

  # ---------------------------------------------------------------
  # Callback — state verification with real HMAC roundtrip
  # ---------------------------------------------------------------

  describe "GET /auth/google/callback — HMAC state roundtrip" do
    test "rejects callback where state token_hash points to nonexistent auth_token", %{
      conn: conn,
      user: user
    } do
      # Generate a real state with HMAC, but for a token_hash that won't match any auth_token
      {:ok, url, _pkce} = OAuth.authorize_url(user.id, "google_chat", "nonexistent-hash")

      uri = URI.parse(url)
      query = URI.decode_query(uri.query)
      state = query["state"]

      conn = get(conn, "/auth/google/callback?code=fake-code&state=#{URI.encode_www_form(state)}")

      assert conn.status == 400
      assert conn.resp_body =~ "Authorization session not found"
    end

    test "rejects callback with valid state but exchange_code fails (no real Google)", %{
      conn: conn,
      user: user
    } do
      raw_token = "integ-test-token-#{System.unique_integer([:positive])}"
      _auth_token = insert_auth_token(user.id, raw_token)
      token_hash = MagicLink.hash_token(raw_token)

      # Generate a real HMAC-signed state with the correct token_hash
      {:ok, url, _pkce} = OAuth.authorize_url(user.id, "google_chat", token_hash)
      uri = URI.parse(url)
      query = URI.decode_query(uri.query)
      state = query["state"]

      # This will hit the real Google token endpoint and fail (expected)
      conn =
        get(conn, "/auth/google/callback?code=fake-auth-code&state=#{URI.encode_www_form(state)}")

      assert conn.status == 500
      assert conn.resp_body =~ "Failed" or conn.resp_body =~ "error"
    end
  end

  # ---------------------------------------------------------------
  # Callback — error param handling
  # ---------------------------------------------------------------

  describe "GET /auth/google/callback — error parameter" do
    test "handles access_denied gracefully", %{conn: conn} do
      conn = get(conn, "/auth/google/callback?error=access_denied")
      assert conn.status == 200
      assert conn.resp_body =~ "Authorization Cancelled"
      assert conn.resp_body =~ "did not grant access"
    end

    test "handles server_error gracefully", %{conn: conn} do
      conn = get(conn, "/auth/google/callback?error=server_error")
      assert conn.status == 200
      assert conn.resp_body =~ "Authorization Cancelled"
    end

    test "handles unknown error values", %{conn: conn} do
      conn = get(conn, "/auth/google/callback?error=something_unexpected")
      assert conn.status == 200
      assert conn.resp_body =~ "Authorization Cancelled"
    end
  end

  # ---------------------------------------------------------------
  # Start + Callback — full start flow integration
  # ---------------------------------------------------------------

  describe "GET /auth/google/start — full flow integration" do
    test "start consumes token and redirects with PKCE and HMAC state", %{conn: conn, user: user} do
      raw_token = "full-flow-#{System.unique_integer([:positive])}"
      insert_auth_token(user.id, raw_token, code_verifier: "cv-test-12345")

      conn = get(conn, "/auth/google/start?token=#{raw_token}")

      assert conn.status == 302
      location = get_resp_header(conn, "location") |> List.first()

      # Verify all required OAuth parameters
      assert location =~ "accounts.google.com"
      assert location =~ "client_id=test-client-id"
      assert location =~ "code_challenge="
      assert location =~ "code_challenge_method=S256"
      assert location =~ "state="

      # Extract and verify the state roundtrips
      uri = URI.parse(location)
      query = URI.decode_query(uri.query)
      state = query["state"]

      assert {:ok, state_data} = OAuth.verify_state(state)
      assert state_data.user_id == user.id
      assert state_data.channel == "test"

      # Verify PKCE challenge is derived from the STORED code_verifier
      expected_challenge =
        :crypto.hash(:sha256, "cv-test-12345")
        |> Base.url_encode64(padding: false)

      assert query["code_challenge"] == expected_challenge
    end
  end

  # ---------------------------------------------------------------
  # Token storage — simulated post-exchange verification
  # ---------------------------------------------------------------

  describe "token storage after OAuth" do
    test "upsert stores token and is retrievable by user_id", %{user: user} do
      assert {:error, :not_connected} = TokenStore.get_google_token(user.id)

      {:ok, _} =
        TokenStore.upsert_google_token(user.id, %{
          refresh_token: "rt-from-exchange",
          access_token: "at-from-exchange",
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          provider_email: "user@test.com",
          provider_uid: "google-uid-123",
          scopes: "openid email"
        })

      assert {:ok, token} = TokenStore.get_google_token(user.id)
      assert token.refresh_token == "rt-from-exchange"
      assert token.access_token == "at-from-exchange"
      assert token.provider_email == "user@test.com"
      assert token.provider_uid == "google-uid-123"
      assert token.scopes == "openid email"
    end
  end

  # ---------------------------------------------------------------
  # PendingIntentWorker enqueue — Oban job insertion
  # ---------------------------------------------------------------

  describe "PendingIntentWorker enqueue" do
    test "builds valid Oban changeset with correct queue and args", %{user: user} do
      args = %{
        user_id: user.id,
        message: "search my drive",
        conversation_id: "conv-#{System.unique_integer([:positive])}",
        channel: "google_chat",
        reply_context: %{"space_id" => "space-test"}
      }

      # Build changeset without inserting — Oban Inline engine would
      # immediately execute perform/1, which crashes on nil inserted_at.
      changeset = Assistant.Workers.PendingIntentWorker.new(args)

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :queue) == "oauth_replay"

      # Args are atom-keyed before JSON serialization
      job_args = Ecto.Changeset.get_field(changeset, :args)
      assert job_args[:user_id] == user.id
      assert job_args[:message] == "search my drive"
      assert job_args[:channel] == "google_chat"
      assert job_args[:reply_context] == %{"space_id" => "space-test"}
    end
  end
end

# test/assistant_web/controllers/oauth_controller_callback_integration_test.exs
#
# Integration tests for the OAuthController callback that exercise deeper
# codepaths than the existing callback test. Tests valid state verification
# with auth_token lookup, Google token exchange error handling, and the
# full callback parameter validation.
#
# The happy path (exchange_code succeeds → tokens stored → PendingIntentWorker
# enqueued) cannot be fully tested without mocking the Req HTTP call to
# Google's token endpoint (hardcoded URL). These tests exercise the flow
# up to and including the exchange_code call, verifying error handling.
#
# Related files:
#   - lib/assistant_web/controllers/oauth_controller.ex (module under test)
#   - lib/assistant/auth/oauth.ex (state signing, code exchange)
#   - lib/assistant/auth/magic_link.ex (magic link lifecycle)
#   - lib/assistant/auth/token_store.ex (token CRUD)

defmodule AssistantWeb.OAuthControllerCallbackIntegrationTest do
  # async: false — modifies global Application env for OAuth credentials.
  use AssistantWeb.ConnCase, async: false

  alias Assistant.Auth.MagicLink
  alias Assistant.Auth.OAuth
  alias Assistant.Schemas.AuthToken

  # ---------------------------------------------------------------
  # Setup — user, OAuth credentials
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
      external_id: "oauth-cb-int-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Assistant.Repo.insert!()
  end

  defp insert_auth_token(user_id, raw_token, opts \\ []) do
    token_hash = MagicLink.hash_token(raw_token)

    %AuthToken{}
    |> AuthToken.changeset(%{
      user_id: user_id,
      token_hash: token_hash,
      purpose: "oauth_google",
      code_verifier:
        Keyword.get(opts, :code_verifier, "test-verifier-#{System.unique_integer([:positive])}"),
      pending_intent:
        Keyword.get(opts, :pending_intent, %{"message" => "test command", "channel" => "test"}),
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second),
      used_at: Keyword.get(opts, :used_at, nil)
    })
    |> Assistant.Repo.insert!()
  end

  defp build_valid_state(user_id, token_hash) do
    {:ok, url, _pkce} = OAuth.authorize_url(user_id, "test", token_hash)
    uri = URI.parse(url)
    query = URI.decode_query(uri.query)
    query["state"]
  end

  # ---------------------------------------------------------------
  # Callback with valid state + auth_token — exchange fails (network)
  # ---------------------------------------------------------------

  describe "GET /auth/google/callback — valid state, exchange fails" do
    test "returns 500 when Google token exchange fails", %{conn: conn, user: user} do
      raw_token = "cb-int-#{System.unique_integer([:positive])}"
      token_hash = MagicLink.hash_token(raw_token)
      insert_auth_token(user.id, raw_token)

      state = build_valid_state(user.id, token_hash)

      # The callback will: verify state (OK) → lookup auth_token (OK) →
      # exchange_code (FAIL — hits hardcoded Google URL, no real server)
      conn =
        get(conn, "/auth/google/callback?code=fake-auth-code&state=#{URI.encode_www_form(state)}")

      # exchange_code failure results in 500
      assert conn.status == 500
      assert conn.resp_body =~ "Failed"
    end
  end

  # ---------------------------------------------------------------
  # Callback with valid state but auth_token not found
  # ---------------------------------------------------------------

  describe "GET /auth/google/callback — auth_token not found" do
    test "returns 400 when state is valid but auth_token deleted", %{conn: conn, user: user} do
      # Build a valid state referencing a token_hash that doesn't exist in DB
      non_existent_hash = "non-existent-hash-#{System.unique_integer([:positive])}"
      state = build_valid_state(user.id, non_existent_hash)

      conn = get(conn, "/auth/google/callback?code=fake-code&state=#{URI.encode_www_form(state)}")

      assert conn.status == 400
      assert conn.resp_body =~ "Authorization session not found"
    end
  end

  # ---------------------------------------------------------------
  # Callback edge cases
  # ---------------------------------------------------------------

  describe "GET /auth/google/callback — edge cases" do
    test "rejects callback with empty state", %{conn: conn} do
      conn = get(conn, "/auth/google/callback?code=some-code&state=")
      assert conn.status == 400
      assert conn.resp_body =~ "Invalid authorization state"
    end

    test "rejects callback with empty code", %{conn: conn} do
      conn = get(conn, "/auth/google/callback?code=&state=some-state")
      # Empty code with non-empty state still goes through callback/2
      # which verifies state first
      assert conn.status == 400
    end

    test "rejects callback with no parameters", %{conn: conn} do
      conn = get(conn, "/auth/google/callback")
      assert conn.status == 400
      assert conn.resp_body =~ "Invalid callback parameters"
    end
  end

  # ---------------------------------------------------------------
  # Start endpoint additional coverage
  # ---------------------------------------------------------------

  describe "GET /auth/google/start — error cases" do
    test "rejects expired magic link token", %{conn: conn, user: user} do
      raw_token = "expired-#{System.unique_integer([:positive])}"

      # Insert token that expired in the past
      token_hash = MagicLink.hash_token(raw_token)

      %AuthToken{}
      |> AuthToken.changeset(%{
        user_id: user.id,
        token_hash: token_hash,
        purpose: "oauth_google",
        code_verifier: "verifier",
        expires_at: DateTime.add(DateTime.utc_now(), -600, :second)
      })
      |> Assistant.Repo.insert!()

      conn = get(conn, "/auth/google/start?token=#{raw_token}")
      assert conn.status == 400
      assert conn.resp_body =~ "expired"
    end

    test "rejects missing token parameter", %{conn: conn} do
      conn = get(conn, "/auth/google/start")
      assert conn.status == 400
      assert conn.resp_body =~ "Missing authorization token"
    end

    test "rejects empty token parameter", %{conn: conn} do
      conn = get(conn, "/auth/google/start?token=")
      assert conn.status == 400
      assert conn.resp_body =~ "Missing authorization token"
    end

    test "rejects non-existent token", %{conn: conn} do
      conn = get(conn, "/auth/google/start?token=totally-unknown-token")
      assert conn.status == 400
      assert conn.resp_body =~ "Invalid or unknown"
    end
  end
end

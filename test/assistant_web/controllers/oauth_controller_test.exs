# test/assistant_web/controllers/oauth_controller_test.exs — Smoke tests for OAuthController.
#
# Verifies the per-user Google OAuth endpoints handle error cases correctly:
#   - /auth/google/start with missing, invalid, expired, and used tokens
#   - /auth/google/callback with denied consent and missing parameters
#
# Happy path tests are limited because they require Google OAuth client
# credentials and external HTTP calls. The callback happy path is tested
# by verifying state verification, token lookup, and error handling.
#
# Related files:
#   - lib/assistant_web/controllers/oauth_controller.ex (module under test)
#   - lib/assistant/auth/magic_link.ex (magic link lifecycle)
#   - lib/assistant/auth/oauth.ex (state verification, code exchange)
#   - lib/assistant/auth/token_store.ex (token storage)

defmodule AssistantWeb.OAuthControllerTest do
  use AssistantWeb.ConnCase, async: true

  alias Assistant.Auth.MagicLink
  alias Assistant.Schemas.AuthToken

  # ---------------------------------------------------------------
  # Setup — create a test user + helper to insert auth_tokens
  # ---------------------------------------------------------------

  setup do
    user = insert_test_user()
    %{user: user}
  end

  defp insert_test_user do
    %Assistant.Schemas.User{}
    |> Assistant.Schemas.User.changeset(%{
      external_id: "oauth-ctrl-test-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Assistant.Repo.insert!()
  end

  defp insert_auth_token(user_id, raw_token, opts \\ []) do
    token_hash = MagicLink.hash_token(raw_token)
    expires_at = Keyword.get(opts, :expires_at, future_expiry())
    used_at = Keyword.get(opts, :used_at, nil)

    %AuthToken{}
    |> AuthToken.changeset(%{
      user_id: user_id,
      token_hash: token_hash,
      purpose: "oauth_google",
      code_verifier: "test-verifier-#{System.unique_integer([:positive])}",
      pending_intent: %{"message" => "test command", "channel" => "test"},
      expires_at: expires_at,
      used_at: used_at
    })
    |> Assistant.Repo.insert!()
  end

  defp future_expiry, do: DateTime.add(DateTime.utc_now(), 600, :second)
  defp past_expiry, do: DateTime.add(DateTime.utc_now(), -600, :second)

  # ---------------------------------------------------------------
  # GET /auth/google/start
  # ---------------------------------------------------------------

  describe "GET /auth/google/start" do
    test "returns 400 when token param is missing", %{conn: conn} do
      conn = get(conn, "/auth/google/start")

      assert conn.status == 400
      assert conn.resp_body =~ "Missing authorization token"
    end

    test "returns 400 when token param is empty", %{conn: conn} do
      conn = get(conn, "/auth/google/start?token=")

      assert conn.status == 400
      assert conn.resp_body =~ "Missing authorization token"
    end

    test "returns 400 when token is not found", %{conn: conn} do
      conn = get(conn, "/auth/google/start?token=nonexistent-token")

      assert conn.status == 400
      assert conn.resp_body =~ "Invalid or unknown authorization link"
    end

    test "returns 400 when token is expired", %{conn: conn, user: user} do
      raw_token = "expired-test-token-#{System.unique_integer([:positive])}"
      insert_auth_token(user.id, raw_token, expires_at: past_expiry())

      conn = get(conn, "/auth/google/start?token=#{raw_token}")

      assert conn.status == 400
      assert conn.resp_body =~ "expired"
    end

    test "returns 400 when token is already used", %{conn: conn, user: user} do
      raw_token = "used-test-token-#{System.unique_integer([:positive])}"
      insert_auth_token(user.id, raw_token, used_at: DateTime.utc_now())

      conn = get(conn, "/auth/google/start?token=#{raw_token}")

      assert conn.status == 400
      assert conn.resp_body =~ "already been used"
    end
  end

  # ---------------------------------------------------------------
  # GET /auth/google/callback
  # ---------------------------------------------------------------

  describe "GET /auth/google/callback" do
    test "returns 400 when params are missing", %{conn: conn} do
      conn = get(conn, "/auth/google/callback")

      assert conn.status == 400
      assert conn.resp_body =~ "Invalid callback parameters"
    end

    test "returns 200 with denied HTML when error param present", %{conn: conn} do
      conn = get(conn, "/auth/google/callback?error=access_denied")

      assert conn.status == 200
      assert conn.resp_body =~ "Authorization Cancelled"
      assert conn.resp_body =~ "did not grant access"
    end

    test "returns 400 when state is invalid", %{conn: conn} do
      conn = get(conn, "/auth/google/callback?code=fake-code&state=invalid-state")

      assert conn.status == 400
      assert conn.resp_body =~ "Invalid authorization state"
    end
  end
end

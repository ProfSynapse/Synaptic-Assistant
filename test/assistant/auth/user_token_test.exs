# test/assistant/auth/user_token_test.exs
#
# Tests for Auth.user_token/1 — the per-user token fetch + refresh flow.
# Covers the three key paths:
#   1. Not connected (no token in DB) → {:error, :not_connected}
#   2. Valid cached token (not expired) → {:ok, access_token}
#   3. Expired token → refresh attempted → error propagated or new token cached
#
# The refresh path goes through serialized_refresh → refresh_and_cache →
# OAuth.refresh_access_token → Goth.Token.fetch (HTTP to Google). Since the
# Goth HTTP call uses a hardcoded URL, we test the error propagation path
# (refresh_failed) which exercises the full codepath without needing Bypass.
#
# Related files:
#   - lib/assistant/integrations/google/auth.ex (module under test)
#   - lib/assistant/auth/oauth.ex (refresh_access_token/1)
#   - lib/assistant/auth/token_store.ex (DB CRUD)

defmodule Assistant.Integrations.Google.AuthUserTokenTest do
  # async: false — modifies global Application env (OAuth credentials).
  use Assistant.DataCase, async: false

  alias Assistant.Auth.TokenStore
  alias Assistant.Integrations.Google.Auth

  # ---------------------------------------------------------------
  # Setup — user + OAuth credentials
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
      external_id: "user-token-test-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Repo.insert!()
  end

  # ---------------------------------------------------------------
  # Path 1: Not connected — no token in DB
  # ---------------------------------------------------------------

  describe "user_token/1 — not connected" do
    test "returns {:error, :not_connected} when no token exists", %{user: user} do
      assert {:error, :not_connected} = Auth.user_token(user.id)
    end

    test "returns {:error, :not_connected} for non-existent user ID" do
      fake_id = Ecto.UUID.generate()
      assert {:error, :not_connected} = Auth.user_token(fake_id)
    end
  end

  # ---------------------------------------------------------------
  # Path 2: Valid cached token (not expired)
  # ---------------------------------------------------------------

  describe "user_token/1 — valid cached token" do
    test "returns cached access_token when token is not expired", %{user: user} do
      future_expiry = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, _} =
        TokenStore.upsert_google_token(user.id, %{
          refresh_token: "rt-cached",
          access_token: "ya29.cached-access-token",
          token_expires_at: future_expiry,
          provider_email: "cached@example.com"
        })

      assert {:ok, "ya29.cached-access-token"} = Auth.user_token(user.id)
    end

    test "returns cached token without attempting refresh", %{user: user} do
      # Token valid for 1 hour — well outside the 60-second buffer
      future_expiry = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, _} =
        TokenStore.upsert_google_token(user.id, %{
          refresh_token: "rt-valid",
          access_token: "ya29.still-valid",
          token_expires_at: future_expiry
        })

      # If this tried to refresh, it would fail (no real Google endpoint),
      # so a successful return proves the cached path was taken.
      assert {:ok, "ya29.still-valid"} = Auth.user_token(user.id)
    end
  end

  # ---------------------------------------------------------------
  # Path 3: Expired token — refresh attempted
  # ---------------------------------------------------------------

  describe "user_token/1 — expired token triggers refresh" do
    test "attempts refresh when token is expired", %{user: user} do
      # Token expired 1 hour ago
      past_expiry = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, _} =
        TokenStore.upsert_google_token(user.id, %{
          refresh_token: "rt-invalid-will-fail",
          access_token: "ya29.expired",
          token_expires_at: past_expiry,
          provider_email: "expired@example.com"
        })

      # Refresh is attempted with fake credentials — Google rejects the
      # refresh token, so OAuth.refresh_access_token/1 returns an error
      # which propagates as {:error, :refresh_failed}.
      assert {:error, :refresh_failed} = Auth.user_token(user.id)
    end

    test "treats nil expiry as expired and attempts refresh", %{user: user} do
      # Token with nil expiry is treated as expired (access_token_valid? returns false)
      {:ok, _} =
        TokenStore.upsert_google_token(user.id, %{
          refresh_token: "rt-nil-expiry",
          access_token: "ya29.nil-expiry",
          token_expires_at: nil,
          provider_email: "nil-expiry@example.com"
        })

      # Refresh attempted — fake credentials rejected by Google.
      assert {:error, :refresh_failed} = Auth.user_token(user.id)
    end

    test "treats token within 60s buffer as expired and attempts refresh", %{user: user} do
      # Token expires in 30 seconds — within the 60-second buffer
      near_expiry = DateTime.add(DateTime.utc_now(), 30, :second)

      {:ok, _} =
        TokenStore.upsert_google_token(user.id, %{
          refresh_token: "rt-near-expiry",
          access_token: "ya29.almost-expired",
          token_expires_at: near_expiry,
          provider_email: "near@example.com"
        })

      # Refresh attempted — fake credentials rejected by Google.
      assert {:error, :refresh_failed} = Auth.user_token(user.id)
    end

    test "returns {:error, :refresh_failed} when credentials missing", %{user: user} do
      past_expiry = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, _} =
        TokenStore.upsert_google_token(user.id, %{
          refresh_token: "rt-no-creds",
          access_token: "ya29.expired-no-creds",
          token_expires_at: past_expiry
        })

      # Remove OAuth credentials — refresh_access_token checks these first
      Application.delete_env(:assistant, :google_oauth_client_id)

      assert {:error, :refresh_failed} = Auth.user_token(user.id)
    end
  end
end

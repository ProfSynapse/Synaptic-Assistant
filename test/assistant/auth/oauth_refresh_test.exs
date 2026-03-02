# test/assistant/auth/oauth_refresh_test.exs
#
# Risk Tier: HIGH — Token refresh is the critical path for per-user Google API access.
#
# Tests the refresh_access_token/1 and revoke_token/1 edge cases in oauth.ex.
# The actual HTTP call to Google's token endpoint uses a hardcoded URL, so we
# cannot intercept with Bypass. Instead we test:
#   - Credential validation (missing client_id/secret)
#   - revoke_token/1 input guards
#   - Error return type contracts
#
# The HTTP success/failure paths are exercised via user_token_test.exs (which
# triggers refresh_access_token through the auth.ex flow) and the
# OAuthController integration tests.
#
# Related files:
#   - lib/assistant/auth/oauth.ex (module under test)
#   - test/assistant/auth/oauth_exchange_test.exs (exchange_code credential tests)
#   - test/assistant/auth/user_token_test.exs (refresh via auth.ex integration)

defmodule Assistant.Auth.OAuthRefreshTest do
  # async: false — modifies global Application env (OAuth credentials)
  use ExUnit.Case, async: false

  alias Assistant.Auth.OAuth

  # ---------------------------------------------------------------
  # Setup — configure and clean up OAuth credentials
  # ---------------------------------------------------------------

  setup do
    Application.put_env(:assistant, :google_oauth_client_id, "test-client-id")
    Application.put_env(:assistant, :google_oauth_client_secret, "test-client-secret")

    on_exit(fn ->
      Application.delete_env(:assistant, :google_oauth_client_id)
      Application.delete_env(:assistant, :google_oauth_client_secret)
    end)
  end

  # ---------------------------------------------------------------
  # refresh_access_token/1 — credential validation
  # ---------------------------------------------------------------

  describe "refresh_access_token/1 — credential validation" do
    test "returns error when client_id is nil" do
      Application.delete_env(:assistant, :google_oauth_client_id)

      assert {:error, :missing_google_oauth_client_id} =
               OAuth.refresh_access_token("any-refresh-token")
    end

    test "returns error when client_secret is nil" do
      Application.delete_env(:assistant, :google_oauth_client_secret)

      assert {:error, :missing_google_oauth_client_secret} =
               OAuth.refresh_access_token("any-refresh-token")
    end

    test "returns error when both credentials are missing (client_id checked first)" do
      Application.delete_env(:assistant, :google_oauth_client_id)
      Application.delete_env(:assistant, :google_oauth_client_secret)

      # The `with` chain checks client_id before client_secret
      assert {:error, :missing_google_oauth_client_id} =
               OAuth.refresh_access_token("any-refresh-token")
    end

    test "returns error when client_id is empty string" do
      Application.put_env(:assistant, :google_oauth_client_id, "")

      assert {:error, :missing_google_oauth_client_id} =
               OAuth.refresh_access_token("any-refresh-token")
    end

    test "returns error when client_secret is empty string" do
      Application.put_env(:assistant, :google_oauth_client_secret, "")

      assert {:error, :missing_google_oauth_client_secret} =
               OAuth.refresh_access_token("any-refresh-token")
    end
  end

  # ---------------------------------------------------------------
  # refresh_access_token/1 — HTTP error handling
  #
  # With valid credentials, the function will attempt a real HTTP call
  # to Google's token endpoint. Since we're using a fake refresh token,
  # Google will reject it. This tests the error propagation path.
  # ---------------------------------------------------------------

  describe "refresh_access_token/1 — error propagation" do
    test "returns {:error, :refresh_failed} for invalid refresh token" do
      # Google will reject this fake token
      result = OAuth.refresh_access_token("fake-refresh-token-that-google-rejects")

      # Should return :refresh_failed (catches all non-200 responses)
      assert {:error, :refresh_failed} = result
    end
  end

  # ---------------------------------------------------------------
  # revoke_token/1 — input guards
  # ---------------------------------------------------------------

  describe "revoke_token/1 — input validation" do
    test "returns {:error, :no_token} for nil input" do
      assert {:error, :no_token} = OAuth.revoke_token(nil)
    end

    test "returns {:error, :no_token} for empty string" do
      assert {:error, :no_token} = OAuth.revoke_token("")
    end

    test "returns {:error, :no_token} for non-binary input" do
      assert {:error, :no_token} = OAuth.revoke_token(123)
    end

    test "returns {:error, :no_token} for atom input" do
      assert {:error, :no_token} = OAuth.revoke_token(:some_token)
    end

    test "attempts revocation for non-empty string (may succeed or fail)" do
      # With a fake token, Google's revocation endpoint may return success
      # (it doesn't validate token format) or failure
      result = OAuth.revoke_token("fake-token-for-revocation")

      # Should either succeed or fail with a structured error — never crash
      assert result in [:ok] or match?({:error, _}, result)
    end
  end

  # ---------------------------------------------------------------
  # exchange_code/2 — credential validation edge cases
  # ---------------------------------------------------------------

  describe "exchange_code/2 — empty string credentials" do
    test "returns error when client_id is empty string" do
      Application.put_env(:assistant, :google_oauth_client_id, "")

      assert {:error, :missing_google_oauth_client_id} =
               OAuth.exchange_code("auth-code", "code-verifier")
    end

    test "returns error when client_secret is empty string" do
      Application.put_env(:assistant, :google_oauth_client_secret, "")

      assert {:error, :missing_google_oauth_client_secret} =
               OAuth.exchange_code("auth-code", "code-verifier")
    end
  end
end

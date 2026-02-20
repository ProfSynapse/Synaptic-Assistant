# test/assistant/auth/oauth_exchange_test.exs
#
# Tests for Auth.OAuth.exchange_code/2 and refresh_access_token/1 —
# credential validation and state HMAC tests. The actual HTTP calls to
# Google's token endpoint cannot be tested via Bypass because the module
# uses a hardcoded URL. Credential validation is tested here; the full
# exchange flow is covered by the OAuthController integration tests.
#
# Related files:
#   - lib/assistant/auth/oauth.ex (module under test)

defmodule Assistant.Auth.OAuthExchangeTest do
  # async: false — this test modifies global Application env
  # (google_oauth_client_id/secret) which races with other async tests.
  use ExUnit.Case, async: false

  alias Assistant.Auth.OAuth

  # ---------------------------------------------------------------
  # Setup — configure OAuth credentials
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
  # exchange_code — credential validation
  # ---------------------------------------------------------------

  describe "exchange_code/2" do
    test "returns error when client_id is missing" do
      Application.delete_env(:assistant, :google_oauth_client_id)

      assert {:error, :missing_google_oauth_client_id} =
               OAuth.exchange_code("code", "verifier")
    end

    test "returns error when client_secret is missing" do
      Application.delete_env(:assistant, :google_oauth_client_secret)

      assert {:error, :missing_google_oauth_client_secret} =
               OAuth.exchange_code("code", "verifier")
    end

    test "returns error when both credentials missing (client_id checked first)" do
      Application.delete_env(:assistant, :google_oauth_client_id)
      Application.delete_env(:assistant, :google_oauth_client_secret)

      assert {:error, :missing_google_oauth_client_id} =
               OAuth.exchange_code("code", "verifier")
    end
  end

  # ---------------------------------------------------------------
  # refresh_access_token — credential validation
  # ---------------------------------------------------------------

  describe "refresh_access_token/1" do
    test "returns error when client_id is missing" do
      Application.delete_env(:assistant, :google_oauth_client_id)

      assert {:error, :missing_google_oauth_client_id} =
               OAuth.refresh_access_token("refresh-token")
    end

    test "returns error when client_secret is missing" do
      Application.delete_env(:assistant, :google_oauth_client_secret)

      assert {:error, :missing_google_oauth_client_secret} =
               OAuth.refresh_access_token("refresh-token")
    end
  end

  # ---------------------------------------------------------------
  # State HMAC expiry
  # ---------------------------------------------------------------

  describe "verify_state/1 — time-based expiry" do
    test "accepts recently generated state" do
      {:ok, url, _pkce} = OAuth.authorize_url("user-1", "test", "hash-1")

      uri = URI.parse(url)
      query = URI.decode_query(uri.query)
      state = query["state"]

      assert {:ok, data} = OAuth.verify_state(state)
      assert data.user_id == "user-1"
      assert data.channel == "test"
      assert data.token_hash == "hash-1"
    end

    test "state contains all expected fields" do
      {:ok, url, _pkce} = OAuth.authorize_url("user-42", "google_chat", "hash-abc")

      uri = URI.parse(url)
      query = URI.decode_query(uri.query)
      state = query["state"]

      assert {:ok, data} = OAuth.verify_state(state)
      assert data.user_id == "user-42"
      assert data.channel == "google_chat"
      assert data.token_hash == "hash-abc"
    end
  end

  # ---------------------------------------------------------------
  # callback_url
  # ---------------------------------------------------------------

  describe "callback_url/0" do
    test "returns the expected callback path" do
      url = OAuth.callback_url()
      assert url =~ "/auth/google/callback"
    end
  end
end

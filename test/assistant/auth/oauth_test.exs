# test/assistant/auth/oauth_test.exs
#
# Smoke tests for the Auth.OAuth module. Tests PKCE generation, state
# signing/verification, and authorize_url building. Does NOT test actual
# HTTP calls (exchange_code, refresh_access_token) — those need Bypass
# and belong in the full TEST phase.
#
# Related files:
#   - lib/assistant/auth/oauth.ex (module under test)

defmodule Assistant.Auth.OAuthTest do
  use ExUnit.Case, async: true

  alias Assistant.Auth.OAuth

  # ---------------------------------------------------------------
  # PKCE generation
  # ---------------------------------------------------------------

  describe "generate_pkce/0" do
    test "returns code_verifier and code_challenge" do
      pkce = OAuth.generate_pkce()

      assert is_binary(pkce.code_verifier)
      assert is_binary(pkce.code_challenge)
      assert byte_size(pkce.code_verifier) > 40
      assert byte_size(pkce.code_challenge) > 20
    end

    test "code_challenge is SHA-256 of code_verifier (S256)" do
      pkce = OAuth.generate_pkce()

      expected_challenge =
        :crypto.hash(:sha256, pkce.code_verifier)
        |> Base.url_encode64(padding: false)

      assert pkce.code_challenge == expected_challenge
    end

    test "generates unique values on each call" do
      pkce1 = OAuth.generate_pkce()
      pkce2 = OAuth.generate_pkce()

      assert pkce1.code_verifier != pkce2.code_verifier
      assert pkce1.code_challenge != pkce2.code_challenge
    end
  end

  # ---------------------------------------------------------------
  # State signing and verification
  # ---------------------------------------------------------------

  describe "authorize_url/3 and verify_state/1 roundtrip" do
    setup do
      # These tests need client_id configured to build the URL
      Application.put_env(:assistant, :google_oauth_client_id, "test-client-id")
      Application.put_env(:assistant, :google_oauth_client_secret, "test-client-secret")

      on_exit(fn ->
        Application.delete_env(:assistant, :google_oauth_client_id)
        Application.delete_env(:assistant, :google_oauth_client_secret)
      end)
    end

    test "authorize_url returns a URL with expected parameters" do
      {:ok, url, pkce} = OAuth.authorize_url("user-123", "google_chat", "token-hash-abc")

      assert is_binary(url)
      assert url =~ "accounts.google.com"
      assert url =~ "client_id=test-client-id"
      assert url =~ "response_type=code"
      assert url =~ "access_type=offline"
      assert url =~ "prompt=consent"
      assert url =~ "code_challenge_method=S256"
      assert url =~ URI.encode_www_form(pkce.code_challenge)
      assert url =~ "state="
      # Scopes should include drive, gmail, calendar but NOT chat.bot
      assert url =~ "drive"
      assert url =~ "gmail"
      assert url =~ "calendar"
      refute url =~ "chat.bot"
    end

    test "authorize_url returns PKCE data" do
      {:ok, _url, pkce} = OAuth.authorize_url("user-123", "google_chat", "token-hash-abc")

      assert is_binary(pkce.code_verifier)
      assert is_binary(pkce.code_challenge)
    end

    test "state parameter roundtrips through verify_state" do
      {:ok, url, _pkce} = OAuth.authorize_url("user-123", "google_chat", "token-hash-abc")

      # Extract state from URL
      uri = URI.parse(url)
      query = URI.decode_query(uri.query)
      state = query["state"]

      assert {:ok, decoded} = OAuth.verify_state(state)
      assert decoded.user_id == "user-123"
      assert decoded.channel == "google_chat"
      assert decoded.token_hash == "token-hash-abc"
    end
  end

  describe "verify_state/1 rejection cases" do
    test "rejects tampered state" do
      assert {:error, :invalid_state} = OAuth.verify_state("dGFtcGVyZWQ")
    end

    test "rejects empty string" do
      assert {:error, :invalid_state} = OAuth.verify_state("")
    end

    test "rejects non-base64 garbage" do
      assert {:error, :invalid_state} = OAuth.verify_state("not-valid-state!!!")
    end
  end

  # ---------------------------------------------------------------
  # Missing credentials
  # ---------------------------------------------------------------

  describe "authorize_url/3 without credentials" do
    test "returns error when client_id is not configured" do
      Application.delete_env(:assistant, :google_oauth_client_id)

      assert {:error, :missing_google_oauth_client_id} =
               OAuth.authorize_url("user-123", "google_chat", "hash")
    end
  end

  # ---------------------------------------------------------------
  # User scopes
  # ---------------------------------------------------------------

  describe "user_scopes/0" do
    test "includes per-user scopes but not chat.bot" do
      scopes = OAuth.user_scopes()

      assert "openid" in scopes
      assert "email" in scopes
      assert "https://www.googleapis.com/auth/drive.readonly" in scopes
      assert "https://www.googleapis.com/auth/gmail.modify" in scopes
      assert "https://www.googleapis.com/auth/calendar" in scopes
      refute "https://www.googleapis.com/auth/chat.bot" in scopes
    end
  end

  # ---------------------------------------------------------------
  # decode_id_token
  # ---------------------------------------------------------------

  describe "decode_id_token/1" do
    test "decodes a valid JWT payload" do
      claims = %{"sub" => "12345", "email" => "user@example.com"}
      payload = Base.url_encode64(Jason.encode!(claims), padding: false)
      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256"}), padding: false)
      token = "#{header}.#{payload}.fake-signature"

      assert {:ok, decoded} = OAuth.decode_id_token(token)
      assert decoded["sub"] == "12345"
      assert decoded["email"] == "user@example.com"
    end

    test "rejects malformed token" do
      assert {:error, :invalid_id_token} = OAuth.decode_id_token("not.a.valid.jwt")
      assert {:error, :invalid_id_token} = OAuth.decode_id_token("single-segment")
    end

    test "rejects token with invalid base64 payload" do
      assert {:error, :invalid_id_token} = OAuth.decode_id_token("aGVhZGVy.!!!invalid!!!.c2ln")
    end
  end
end

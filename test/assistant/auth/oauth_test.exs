# test/assistant/auth/oauth_test.exs — OAuth module pure function tests.
#
# Risk Tier: CRITICAL — PKCE and HMAC state verification are core security controls.
# Tests pure functions only: PKCE generation, state signing/verification, scopes.
# Token exchange and refresh are HTTP-bound and tested via controller integration.

defmodule Assistant.Auth.OAuthTest do
  use ExUnit.Case, async: true

  alias Assistant.Auth.OAuth

  setup do
    # Set required config for OAuth module
    Application.put_env(:assistant, :google_oauth_client_id, "test-client-id")
    Application.put_env(:assistant, :google_oauth_client_secret, "test-client-secret")

    current = Application.get_env(:assistant, AssistantWeb.Endpoint, [])

    merged =
      current
      |> Keyword.put(:url, host: "test.example.com")
      |> Keyword.put(
        :secret_key_base,
        "27fsLlwxFAdrfzZvsTKefyNOFNT2ucWuIv/xYSS2myafQ6FEGytY1Gew0fD2BWU2"
      )

    Application.put_env(:assistant, AssistantWeb.Endpoint, merged)

    on_exit(fn ->
      Application.put_env(:assistant, AssistantWeb.Endpoint, current)
      Application.delete_env(:assistant, :google_oauth_client_id)
      Application.delete_env(:assistant, :google_oauth_client_secret)
    end)

    :ok
  end

  # -------------------------------------------------------------------
  # PKCE helpers
  # -------------------------------------------------------------------

  describe "generate_code_verifier/0" do
    test "returns a base64url-encoded string" do
      verifier = OAuth.generate_code_verifier()
      assert is_binary(verifier)
      assert byte_size(verifier) > 0
      # Base64url should decode without error
      assert {:ok, _} = Base.url_decode64(verifier, padding: false)
    end

    test "generates unique values each call" do
      v1 = OAuth.generate_code_verifier()
      v2 = OAuth.generate_code_verifier()
      refute v1 == v2
    end
  end

  describe "generate_code_challenge/1" do
    test "produces SHA-256 hash of verifier, base64url-encoded" do
      verifier = "test-verifier-value"
      challenge = OAuth.generate_code_challenge(verifier)

      expected =
        :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

      assert challenge == expected
    end

    test "different verifiers produce different challenges" do
      c1 = OAuth.generate_code_challenge("verifier-1")
      c2 = OAuth.generate_code_challenge("verifier-2")
      refute c1 == c2
    end
  end

  # -------------------------------------------------------------------
  # build_authorization_url/2
  # -------------------------------------------------------------------

  describe "build_authorization_url/2" do
    test "returns a valid Google OAuth URL with required params" do
      user_id = "user-uuid-123"

      assert {:ok, %{url: url, code_verifier: verifier}} =
               OAuth.build_authorization_url(user_id,
                 channel: "google_chat",
                 token_hash: "abc123"
               )

      assert is_binary(url)
      assert is_binary(verifier)
      assert url =~ "https://accounts.google.com/o/oauth2/v2/auth?"
      assert url =~ "client_id=test-client-id"
      assert url =~ "redirect_uri="
      assert url =~ "response_type=code"
      assert url =~ "access_type=offline"
      assert url =~ "prompt=consent"
      assert url =~ "code_challenge_method=S256"
      assert url =~ "code_challenge="
      assert url =~ "state="
    end

    test "code_challenge matches SHA-256 of code_verifier" do
      {:ok, %{url: url, code_verifier: verifier}} =
        OAuth.build_authorization_url("user-1", channel: "test")

      %{"code_challenge" => challenge} =
        url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      expected = OAuth.generate_code_challenge(verifier)
      assert challenge == expected
    end

    test "accepts a provided code_verifier" do
      my_verifier = "my-custom-verifier"

      {:ok, %{code_verifier: returned_verifier}} =
        OAuth.build_authorization_url("user-1", code_verifier: my_verifier)

      assert returned_verifier == my_verifier
    end

    test "returns error when client_id not configured" do
      Application.delete_env(:assistant, :google_oauth_client_id)

      assert {:error, :missing_google_oauth_client_id} =
               OAuth.build_authorization_url("user-1")
    end

    test "includes all user scopes" do
      {:ok, %{url: url}} = OAuth.build_authorization_url("user-1")

      for scope <- OAuth.user_scopes() do
        assert url =~ URI.encode_www_form(scope) || url =~ scope
      end
    end
  end

  # -------------------------------------------------------------------
  # verify_state/1
  # -------------------------------------------------------------------

  describe "verify_state/1" do
    test "verifies a freshly signed state" do
      {:ok, %{url: url}} =
        OAuth.build_authorization_url("user-abc",
          channel: "google_chat",
          token_hash: "hash123"
        )

      %{"state" => state} =
        url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert {:ok, %{user_id: "user-abc", channel: "google_chat", token_hash: "hash123"}} =
               OAuth.verify_state(state)
    end

    test "rejects tampered state" do
      {:ok, %{url: url}} = OAuth.build_authorization_url("user-1")

      %{"state" => state} =
        url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      # Tamper with the state by flipping a character
      tampered =
        case Base.url_decode64(state, padding: false) do
          {:ok, decoded} ->
            # Swap first char
            <<_first, rest::binary>> = decoded
            Base.url_encode64(<<"X", rest::binary>>, padding: false)

          :error ->
            "completely-invalid"
        end

      assert {:error, :invalid_state} = OAuth.verify_state(tampered)
    end

    test "rejects non-base64 garbage" do
      assert {:error, :invalid_state} = OAuth.verify_state("!!!not-base64!!!")
    end

    test "rejects empty state" do
      assert {:error, :invalid_state} = OAuth.verify_state("")
    end

    test "rejects state with wrong number of pipe-delimited fields" do
      # Valid base64 but wrong internal format
      bad = Base.url_encode64("only|two", padding: false)
      assert {:error, :invalid_state} = OAuth.verify_state(bad)
    end
  end

  # -------------------------------------------------------------------
  # user_scopes/0
  # -------------------------------------------------------------------

  describe "user_scopes/0" do
    test "includes required scopes and excludes chat.bot" do
      scopes = OAuth.user_scopes()

      assert "openid" in scopes
      assert "email" in scopes
      assert "https://www.googleapis.com/auth/gmail.modify" in scopes
      assert "https://www.googleapis.com/auth/calendar" in scopes
      assert "https://www.googleapis.com/auth/drive.readonly" in scopes
      refute "https://www.googleapis.com/auth/chat.bot" in scopes
    end
  end
end

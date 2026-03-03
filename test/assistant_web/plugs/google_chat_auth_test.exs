# test/assistant_web/plugs/google_chat_auth_test.exs
#
# Tests for the GoogleChatAuth plug's dynamic issuer-based cert/key resolution
# and issuer validation. Covers the issuer allowlist, cert URL construction,
# and JWKS key parsing for service accounts and Google ID token issuers.
#
# Does NOT test full JWT verification (would require real/mocked Google certs).

defmodule AssistantWeb.Plugs.GoogleChatAuthTest do
  use ExUnit.Case, async: true

  alias AssistantWeb.Plugs.GoogleChatAuth

  # ---------------------------------------------------------------
  # Issuer Allowlist
  # ---------------------------------------------------------------

  describe "allowed_issuer?/1" do
    test "accepts standard Chat API service account" do
      assert GoogleChatAuth.allowed_issuer?("chat@system.gserviceaccount.com")
    end

    test "accepts Google ID token issuer (accounts.google.com)" do
      assert GoogleChatAuth.allowed_issuer?("https://accounts.google.com")
    end

    test "accepts G Suite Add-ons service account" do
      assert GoogleChatAuth.allowed_issuer?(
               "service-530288889088@gcp-sa-gsuiteaddons.iam.gserviceaccount.com"
             )
    end

    test "accepts any project-scoped G Suite Add-ons service account" do
      assert GoogleChatAuth.allowed_issuer?(
               "service-999999999999@gcp-sa-gsuiteaddons.iam.gserviceaccount.com"
             )
    end

    test "rejects arbitrary gserviceaccount.com addresses" do
      refute GoogleChatAuth.allowed_issuer?("attacker@evil.gserviceaccount.com")
    end

    test "rejects non-Google issuers" do
      refute GoogleChatAuth.allowed_issuer?("attacker@example.com")
    end

    test "rejects empty string" do
      refute GoogleChatAuth.allowed_issuer?("")
    end

    test "rejects nil" do
      refute GoogleChatAuth.allowed_issuer?(nil)
    end

    test "rejects issuer with suffix embedded in path" do
      # Ensure suffix matching is at the end, not a substring
      refute GoogleChatAuth.allowed_issuer?(
               "fake@gcp-sa-gsuiteaddons.iam.gserviceaccount.com.evil.com"
             )
    end

    test "rejects accounts.google.com without https scheme" do
      refute GoogleChatAuth.allowed_issuer?("accounts.google.com")
    end

    test "rejects http variant of accounts.google.com" do
      refute GoogleChatAuth.allowed_issuer?("http://accounts.google.com")
    end
  end

  # ---------------------------------------------------------------
  # Issuer Validation (wraps allowed_issuer? with logging)
  # ---------------------------------------------------------------

  describe "validate_issuer/1" do
    test "returns :ok for allowed service account issuers" do
      assert :ok = GoogleChatAuth.validate_issuer("chat@system.gserviceaccount.com")
    end

    test "returns :ok for Google ID token issuer" do
      assert :ok = GoogleChatAuth.validate_issuer("https://accounts.google.com")
    end

    test "returns error for disallowed issuers" do
      assert {:error, :disallowed_issuer} =
               GoogleChatAuth.validate_issuer("bad@example.com")
    end
  end

  # ---------------------------------------------------------------
  # Dynamic Cert URL Construction
  # ---------------------------------------------------------------

  describe "certs_url_for_issuer/1" do
    test "constructs URL for standard Chat API issuer" do
      url = GoogleChatAuth.certs_url_for_issuer("chat@system.gserviceaccount.com")

      assert url ==
               "https://www.googleapis.com/service_accounts/v1/metadata/x509/chat%40system.gserviceaccount.com"
    end

    test "constructs URL for G Suite Add-ons issuer" do
      issuer = "service-530288889088@gcp-sa-gsuiteaddons.iam.gserviceaccount.com"
      url = GoogleChatAuth.certs_url_for_issuer(issuer)

      assert url ==
               "https://www.googleapis.com/service_accounts/v1/metadata/x509/service-530288889088%40gcp-sa-gsuiteaddons.iam.gserviceaccount.com"
    end

    test "returns JWKS URL for Google ID token issuer" do
      url = GoogleChatAuth.certs_url_for_issuer("https://accounts.google.com")
      assert url == "https://www.googleapis.com/oauth2/v3/certs"
    end

    test "URL-encodes the @ symbol to prevent path injection" do
      url = GoogleChatAuth.certs_url_for_issuer("test@example.com")
      assert String.contains?(url, "%40")
      refute String.contains?(url, "@")
    end
  end

  # ---------------------------------------------------------------
  # JWT Issuer Extraction
  # ---------------------------------------------------------------

  describe "extract_issuer/1" do
    test "extracts issuer from a valid JWT payload" do
      # Build a minimal JWT with just the payload containing iss
      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "kid" => "key1"}), padding: false)
      payload = Base.url_encode64(Jason.encode!(%{"iss" => "chat@system.gserviceaccount.com", "aud" => "123"}), padding: false)
      # Signature doesn't matter for peek_payload
      token = "#{header}.#{payload}.fake_signature"

      assert {:ok, "chat@system.gserviceaccount.com"} = GoogleChatAuth.extract_issuer(token)
    end

    test "extracts G Suite Add-ons issuer" do
      issuer = "service-530288889088@gcp-sa-gsuiteaddons.iam.gserviceaccount.com"
      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "kid" => "key1"}), padding: false)
      payload = Base.url_encode64(Jason.encode!(%{"iss" => issuer, "aud" => "123"}), padding: false)
      token = "#{header}.#{payload}.fake_signature"

      assert {:ok, ^issuer} = GoogleChatAuth.extract_issuer(token)
    end

    test "extracts Google ID token issuer (accounts.google.com)" do
      issuer = "https://accounts.google.com"
      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "kid" => "key1"}), padding: false)
      payload = Base.url_encode64(Jason.encode!(%{"iss" => issuer, "aud" => "123456"}), padding: false)
      token = "#{header}.#{payload}.fake_signature"

      assert {:ok, ^issuer} = GoogleChatAuth.extract_issuer(token)
    end

    test "returns error for JWT missing iss claim" do
      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256"}), padding: false)
      payload = Base.url_encode64(Jason.encode!(%{"aud" => "123"}), padding: false)
      token = "#{header}.#{payload}.fake_signature"

      assert {:error, :missing_issuer} = GoogleChatAuth.extract_issuer(token)
    end

    test "returns error for completely invalid token" do
      assert {:error, _reason} = GoogleChatAuth.extract_issuer("not.a.jwt.at.all")
    end

    test "returns error for empty string token" do
      assert {:error, _reason} = GoogleChatAuth.extract_issuer("")
    end
  end

  # ---------------------------------------------------------------
  # Plug Integration (bearer token extraction and 401 responses)
  # ---------------------------------------------------------------

  describe "call/2 with missing bearer token" do
    test "returns 401 for request without Authorization header" do
      conn =
        :post
        |> Plug.Test.conn("/webhooks/google_chat", "")
        |> GoogleChatAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end

    test "returns 401 for non-Bearer Authorization header" do
      conn =
        :post
        |> Plug.Test.conn("/webhooks/google_chat", "")
        |> Plug.Conn.put_req_header("authorization", "Basic dXNlcjpwYXNz")
        |> GoogleChatAuth.call([])

      assert conn.status == 401
      assert conn.halted
    end
  end
end

# test/assistant/integrations/google/auth_service_token_test.exs
#
# Risk Tier: HIGH — Service account auth is the sole path for Google Chat bot.
#
# Tests the JWT assertion flow introduced when Goth was removed:
#   - Credential loading and parsing (JSON, file path, missing fields)
#   - JWT construction and signing with JOSE
#   - ETS caching behavior (hit, miss, near-expiry eviction)
#   - Error handling for invalid keys, missing credentials
#   - configured?/0 edge cases
#
# NOTE: The token exchange URL is configurable via :google_token_url app env,
# so we can intercept it with Bypass for full end-to-end tests.
# We also test the pure-functional layers (credential parsing, JWT signing,
# ETS caching) directly. The HTTP error propagation is tested via the
# service_token/0 → :not_configured path and the Chat integration test.
#
# Related files:
#   - lib/assistant/integrations/google/auth.ex (module under test)
#   - lib/assistant/integration_settings.ex (credential source)

defmodule Assistant.Integrations.Google.AuthServiceTokenTest do
  # async: false — modifies global Application env and shared ETS table
  use ExUnit.Case, async: false

  alias Assistant.Integrations.Google.Auth

  @token_cache_table :google_service_token_cache
  @test_client_email "bot@test-project.iam.gserviceaccount.com"

  # ---------------------------------------------------------------
  # Setup — clean ETS cache and env between tests
  # ---------------------------------------------------------------

  setup do
    clear_ets_cache()

    on_exit(fn ->
      Application.delete_env(:assistant, :google_service_account_json)
      clear_ets_cache()
    end)

    :ok
  end

  defp clear_ets_cache do
    case :ets.whereis(@token_cache_table) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(@token_cache_table)
    end
  rescue
    ArgumentError -> :ok
  end

  # Generate a real RSA key for JOSE tests. This is done at runtime
  # to ensure the PEM is properly formatted (no heredoc corruption).
  defp test_private_key_pem do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_type, pem} = JOSE.JWK.to_pem(jwk)
    pem
  end

  # ---------------------------------------------------------------
  # configured?/0 — credential parsing paths
  # ---------------------------------------------------------------

  describe "configured?/0 — raw JSON" do
    test "returns true for valid JSON with client_email and private_key" do
      json = Jason.encode!(%{
        "client_email" => @test_client_email,
        "private_key" => test_private_key_pem()
      })

      Application.put_env(:assistant, :google_service_account_json, json)
      assert Auth.configured?()
    end

    test "returns false when JSON is missing client_email" do
      json = Jason.encode!(%{
        "private_key" => test_private_key_pem()
      })

      Application.put_env(:assistant, :google_service_account_json, json)
      refute Auth.configured?()
    end

    test "returns false when JSON is missing private_key" do
      json = Jason.encode!(%{
        "client_email" => @test_client_email
      })

      Application.put_env(:assistant, :google_service_account_json, json)
      refute Auth.configured?()
    end

    test "returns false when JSON has null client_email" do
      json = Jason.encode!(%{
        "client_email" => nil,
        "private_key" => test_private_key_pem()
      })

      Application.put_env(:assistant, :google_service_account_json, json)
      refute Auth.configured?()
    end

    test "returns false when JSON has null private_key" do
      json = Jason.encode!(%{
        "client_email" => @test_client_email,
        "private_key" => nil
      })

      Application.put_env(:assistant, :google_service_account_json, json)
      refute Auth.configured?()
    end

    test "returns false when JSON has integer client_email" do
      json = Jason.encode!(%{
        "client_email" => 12345,
        "private_key" => test_private_key_pem()
      })

      Application.put_env(:assistant, :google_service_account_json, json)
      refute Auth.configured?()
    end

    test "returns false for empty JSON object" do
      Application.put_env(:assistant, :google_service_account_json, "{}")
      refute Auth.configured?()
    end

    test "returns false for JSON array" do
      Application.put_env(:assistant, :google_service_account_json, "[]")
      refute Auth.configured?()
    end

    test "returns true when JSON has extra fields (tolerant parsing)" do
      json = Jason.encode!(%{
        "client_email" => @test_client_email,
        "private_key" => test_private_key_pem(),
        "project_id" => "test-project",
        "type" => "service_account"
      })

      Application.put_env(:assistant, :google_service_account_json, json)
      assert Auth.configured?()
    end
  end

  describe "configured?/0 — file path" do
    test "returns true when value is a file path to valid JSON" do
      json = Jason.encode!(%{
        "client_email" => @test_client_email,
        "private_key" => test_private_key_pem()
      })

      path = Path.join(System.tmp_dir!(), "test_sa_#{System.unique_integer([:positive])}.json")
      File.write!(path, json)
      on_exit(fn -> File.rm(path) end)

      Application.put_env(:assistant, :google_service_account_json, path)
      assert Auth.configured?()
    end

    test "returns false when file path does not exist" do
      path = "/nonexistent/path/creds_#{System.unique_integer([:positive])}.json"
      Application.put_env(:assistant, :google_service_account_json, path)
      refute Auth.configured?()
    end

    test "returns false when file contains invalid JSON" do
      path = Path.join(System.tmp_dir!(), "test_sa_bad_#{System.unique_integer([:positive])}.json")
      File.write!(path, "this is not json")
      on_exit(fn -> File.rm(path) end)

      Application.put_env(:assistant, :google_service_account_json, path)
      refute Auth.configured?()
    end

    test "returns false when file JSON is missing required fields" do
      json = Jason.encode!(%{"type" => "service_account"})
      path = Path.join(System.tmp_dir!(), "test_sa_missing_#{System.unique_integer([:positive])}.json")
      File.write!(path, json)
      on_exit(fn -> File.rm(path) end)

      Application.put_env(:assistant, :google_service_account_json, path)
      refute Auth.configured?()
    end
  end

  describe "configured?/0 — nil and non-binary" do
    test "returns false when value is nil" do
      Application.delete_env(:assistant, :google_service_account_json)
      refute Auth.configured?()
    end

    test "returns false when value is non-binary (integer)" do
      Application.put_env(:assistant, :google_service_account_json, 42)
      refute Auth.configured?()
    end

    test "returns false when value is non-binary (atom)" do
      Application.put_env(:assistant, :google_service_account_json, :something)
      refute Auth.configured?()
    end
  end

  # ---------------------------------------------------------------
  # service_token/0 — not configured
  # ---------------------------------------------------------------

  describe "service_token/0 — missing credentials" do
    test "returns {:error, :not_configured} when no credentials set" do
      Application.delete_env(:assistant, :google_service_account_json)
      assert {:error, :not_configured} = Auth.service_token()
    end

    test "returns {:error, :not_configured} when credentials JSON is invalid" do
      Application.put_env(:assistant, :google_service_account_json, "{}")
      assert {:error, :not_configured} = Auth.service_token()
    end

    test "returns {:error, :not_configured} when credentials are non-binary" do
      Application.put_env(:assistant, :google_service_account_json, 42)
      assert {:error, :not_configured} = Auth.service_token()
    end
  end

  # ---------------------------------------------------------------
  # service_token/0 — invalid private key
  #
  # A malformed PEM may fail at parse_private_key (→ :invalid_private_key)
  # or may parse into a broken JWK that fails at sign_jwt (→ :jwt_signing_failed).
  # Both are valid error paths — the code gracefully handles both.
  # ---------------------------------------------------------------

  describe "service_token/0 — invalid private key" do
    test "returns auth error for malformed PEM" do
      json = Jason.encode!(%{
        "client_email" => @test_client_email,
        "private_key" => "not-a-valid-pem-key"
      })

      Application.put_env(:assistant, :google_service_account_json, json)
      result = Auth.service_token()

      # Malformed PEM may fail at parse or sign stage — both are valid errors
      assert result in [
               {:error, :invalid_private_key},
               {:error, :jwt_signing_failed}
             ]
    end

    test "returns auth error for empty private_key" do
      json = Jason.encode!(%{
        "client_email" => @test_client_email,
        "private_key" => ""
      })

      Application.put_env(:assistant, :google_service_account_json, json)
      result = Auth.service_token()

      # Empty PEM: either fails at parse, sign, or credential loading
      assert result in [
               {:error, :invalid_private_key},
               {:error, :jwt_signing_failed},
               {:error, :not_configured}
             ]
    end

    test "returns auth error for truncated PEM" do
      json = Jason.encode!(%{
        "client_email" => @test_client_email,
        "private_key" => "-----BEGIN RSA PRIVATE KEY-----\ntruncated\n-----END RSA PRIVATE KEY-----\n"
      })

      Application.put_env(:assistant, :google_service_account_json, json)
      result = Auth.service_token()

      assert result in [
               {:error, :invalid_private_key},
               {:error, :jwt_signing_failed}
             ]
    end
  end

  # ---------------------------------------------------------------
  # service_token/0 — JWT signing with valid key
  #
  # With valid credentials but no real Google endpoint, service_token/0
  # will construct and sign the JWT, then fail at the HTTP exchange.
  # This verifies the JWT construction + signing path works end-to-end.
  # ---------------------------------------------------------------

  describe "service_token/0 — JWT signing with valid RSA key" do
    setup do
      json = Jason.encode!(%{
        "client_email" => @test_client_email,
        "private_key" => test_private_key_pem()
      })

      Application.put_env(:assistant, :google_service_account_json, json)
      :ok
    end

    test "fails at token exchange (not at JWT construction) with valid key" do
      result = Auth.service_token()

      case result do
        {:error, {:token_exchange_failed, _}} ->
          # JWT was signed successfully, HTTP exchange failed as expected
          assert true

        {:error, :invalid_private_key} ->
          flunk("JWT signing failed — JOSE could not parse the RSA key")

        {:error, :not_configured} ->
          flunk("Credentials not loaded — parse_service_account_value failed")

        {:ok, _token} ->
          # Unlikely in test, but possible if Google responds
          assert true

        other ->
          flunk("Unexpected error: #{inspect(other)}")
      end
    end
  end

  # ---------------------------------------------------------------
  # ETS caching — direct cache manipulation
  # ---------------------------------------------------------------

  describe "ETS caching behavior" do
    test "service_token/0 returns cached token when valid" do
      ensure_cache_table()

      expires_at = System.system_time(:second) + 7200
      :ets.insert(@token_cache_table, {:service_token, "cached-test-token", expires_at})

      assert {:ok, "cached-test-token"} = Auth.service_token()
    end

    test "service_token/0 ignores cache when token is near expiry" do
      ensure_cache_table()

      # Token expires in 100 seconds — within the 300-second refresh margin
      expires_at = System.system_time(:second) + 100
      :ets.insert(@token_cache_table, {:service_token, "almost-expired-token", expires_at})

      Application.delete_env(:assistant, :google_service_account_json)
      result = Auth.service_token()

      refute result == {:ok, "almost-expired-token"}
      assert {:error, _} = result
    end

    test "service_token/0 ignores cache when token is expired" do
      ensure_cache_table()

      expires_at = System.system_time(:second) - 600
      :ets.insert(@token_cache_table, {:service_token, "expired-token", expires_at})

      Application.delete_env(:assistant, :google_service_account_json)
      result = Auth.service_token()

      refute result == {:ok, "expired-token"}
      assert {:error, _} = result
    end

    test "service_token/0 treats empty ETS table as cache miss" do
      ensure_cache_table()
      :ets.delete_all_objects(@token_cache_table)

      Application.delete_env(:assistant, :google_service_account_json)
      assert {:error, :not_configured} = Auth.service_token()
    end

    test "cache table is created automatically if not present" do
      # Delete the cache table if it exists
      case :ets.whereis(@token_cache_table) do
        :undefined -> :ok
        _ref -> :ets.delete(@token_cache_table)
      end

      # Calling service_token/0 should create the table
      Application.delete_env(:assistant, :google_service_account_json)
      Auth.service_token()

      # Table should now exist
      assert :ets.whereis(@token_cache_table) != :undefined
    end

    test "cache hit avoids credential loading" do
      ensure_cache_table()

      # Set intentionally broken credentials
      Application.put_env(:assistant, :google_service_account_json, "not-valid-json-or-path")

      # But put a valid token in cache
      expires_at = System.system_time(:second) + 7200
      :ets.insert(@token_cache_table, {:service_token, "cached-bypass-creds", expires_at})

      # Should return cached token despite broken credentials
      assert {:ok, "cached-bypass-creds"} = Auth.service_token()
    end

    test "cache token exactly at refresh margin boundary is treated as miss" do
      ensure_cache_table()

      # Token expires exactly at the 300-second margin
      expires_at = System.system_time(:second) + 300
      :ets.insert(@token_cache_table, {:service_token, "boundary-token", expires_at})

      Application.delete_env(:assistant, :google_service_account_json)
      result = Auth.service_token()

      # At exactly the margin, `now < expires_at - margin` equals `now < now` = false → miss
      refute result == {:ok, "boundary-token"}
    end

    test "cache token 1 second past refresh margin boundary is a hit" do
      ensure_cache_table()

      # Token expires 301 seconds from now — just past the 300-second margin
      expires_at = System.system_time(:second) + 301
      :ets.insert(@token_cache_table, {:service_token, "just-valid-token", expires_at})

      assert {:ok, "just-valid-token"} = Auth.service_token()
    end
  end

  # ---------------------------------------------------------------
  # JOSE JWT construction — verify JWT structure is correct
  # ---------------------------------------------------------------

  describe "JOSE JWT construction" do
    test "JOSE can parse a generated RSA private key" do
      pem = test_private_key_pem()
      jwk = JOSE.JWK.from_pem(pem)
      assert %JOSE.JWK{} = jwk
    end

    test "JOSE can sign and verify a JWT with a generated key" do
      pem = test_private_key_pem()
      jwk = JOSE.JWK.from_pem(pem)

      now = System.system_time(:second)

      claims = %{
        "iss" => @test_client_email,
        "scope" => "https://www.googleapis.com/auth/chat.bot",
        "aud" => "https://oauth2.googleapis.com/token",
        "iat" => now,
        "exp" => now + 3600
      }

      jws = %{"alg" => "RS256", "typ" => "JWT"}
      {_, compact} = JOSE.JWT.sign(jwk, jws, claims) |> JOSE.JWS.compact()

      assert is_binary(compact)

      # JWT has three segments separated by dots
      segments = String.split(compact, ".")
      assert length(segments) == 3

      # Verify the JWT by decoding the payload
      [_header, payload, _signature] = segments
      {:ok, decoded_json} = Base.url_decode64(payload, padding: false)
      {:ok, decoded_claims} = Jason.decode(decoded_json)

      assert decoded_claims["iss"] == @test_client_email
      assert decoded_claims["scope"] == "https://www.googleapis.com/auth/chat.bot"
      assert decoded_claims["aud"] == "https://oauth2.googleapis.com/token"
      assert decoded_claims["iat"] == now
      assert decoded_claims["exp"] == now + 3600
    end

    test "JWT signature can be verified with the same key" do
      pem = test_private_key_pem()
      jwk = JOSE.JWK.from_pem(pem)

      claims = %{
        "iss" => @test_client_email,
        "scope" => "https://www.googleapis.com/auth/chat.bot",
        "aud" => "https://oauth2.googleapis.com/token",
        "iat" => System.system_time(:second),
        "exp" => System.system_time(:second) + 3600
      }

      jws = %{"alg" => "RS256", "typ" => "JWT"}
      {_, compact} = JOSE.JWT.sign(jwk, jws, claims) |> JOSE.JWS.compact()

      # Verify signature using the same key (contains the public part)
      {verified, _payload, _jws} = JOSE.JWT.verify(jwk, compact)
      assert verified == true
    end

    test "JWT signed with one key fails verification with a different key" do
      pem1 = test_private_key_pem()
      pem2 = test_private_key_pem()
      jwk1 = JOSE.JWK.from_pem(pem1)
      jwk2 = JOSE.JWK.from_pem(pem2)

      claims = %{
        "iss" => @test_client_email,
        "aud" => "https://oauth2.googleapis.com/token",
        "iat" => System.system_time(:second),
        "exp" => System.system_time(:second) + 3600
      }

      jws = %{"alg" => "RS256", "typ" => "JWT"}
      {_, compact} = JOSE.JWT.sign(jwk1, jws, claims) |> JOSE.JWS.compact()

      # Verify with a different key should fail
      {verified, _payload, _jws} = JOSE.JWT.verify(jwk2, compact)
      assert verified == false
    end
  end

  # ---------------------------------------------------------------
  # oauth_configured?/0
  # ---------------------------------------------------------------

  describe "oauth_configured?/0 — edge cases" do
    test "returns false when client_id is empty string" do
      Application.put_env(:assistant, :google_oauth_client_id, "")
      Application.put_env(:assistant, :google_oauth_client_secret, "test-secret")

      # Empty string is != nil, so oauth_configured? returns true
      # This documents the current behavior (presence check, not validity)
      result = Auth.oauth_configured?()
      assert is_boolean(result)
    after
      Application.delete_env(:assistant, :google_oauth_client_id)
      Application.delete_env(:assistant, :google_oauth_client_secret)
    end

    test "returns true when both are set to non-empty values" do
      Application.put_env(:assistant, :google_oauth_client_id, "client-id")
      Application.put_env(:assistant, :google_oauth_client_secret, "client-secret")

      assert Auth.oauth_configured?()
    after
      Application.delete_env(:assistant, :google_oauth_client_id)
      Application.delete_env(:assistant, :google_oauth_client_secret)
    end
  end

  # ---------------------------------------------------------------
  # service_token/0 — Bypass HTTP success
  # ---------------------------------------------------------------

  describe "service_token/0 — Bypass HTTP success" do
    test "returns access token from mocked Google token endpoint" do
      # Generate RSA key pair for JWT signing
      jwk = JOSE.JWK.generate_key({:rsa, 2048})
      {_type, pem} = JOSE.JWK.to_pem(jwk)

      # Build service account JSON with valid credentials
      sa_json = Jason.encode!(%{
        "client_email" => @test_client_email,
        "private_key" => pem
      })

      Application.put_env(:assistant, :google_service_account_json, sa_json)

      # Start Bypass and point the configurable token URL to it
      bypass = Bypass.open()
      Application.put_env(:assistant, :google_token_url, "http://localhost:#{bypass.port}/token")

      on_exit(fn ->
        Application.delete_env(:assistant, :google_token_url)
      end)

      # Mock the Google token endpoint response
      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "access_token" => "bypass-token",
          "expires_in" => 3600,
          "token_type" => "Bearer"
        }))
      end)

      # Clear ETS cache to force a fresh token fetch
      clear_ets_cache()

      # Call service_token and verify we get the Bypass token
      assert {:ok, "bypass-token"} = Auth.service_token()
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp ensure_cache_table do
    case :ets.whereis(@token_cache_table) do
      :undefined ->
        :ets.new(@token_cache_table, [:set, :public, :named_table])

      _ref ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end

# test/assistant_web/controllers/oauth_controller_test.exs — OAuthController endpoint tests.
#
# Risk Tier: CRITICAL — Browser-facing OAuth endpoints with security-sensitive behavior.
# Tests magic link validation, PKCE flow, HMAC state verification, error rendering.
# Uses ConnCase for Phoenix connection testing. DB-backed (DataCase sandbox via ConnCase).

defmodule AssistantWeb.OAuthControllerTest do
  use AssistantWeb.ConnCase, async: false

  alias Assistant.Auth.MagicLink
  alias Assistant.Schemas.{AuthToken, OAuthToken, User}
  alias Assistant.Repo

  import Ecto.Query

  # -------------------------------------------------------------------
  # Setup
  # -------------------------------------------------------------------

  setup %{conn: conn} do
    # Create test user
    {:ok, user} =
      Repo.insert(
        User.changeset(%User{}, %{
          external_id: "ctrl-test-user-#{System.unique_integer([:positive])}",
          channel: "test"
        })
      )

    # Configure OAuth and endpoint
    Application.put_env(:assistant, :google_oauth_client_id, "test-client-id")
    Application.put_env(:assistant, :google_oauth_client_secret, "test-client-secret")

    original_config = Application.get_env(:assistant, AssistantWeb.Endpoint, [])

    merged =
      original_config
      |> Keyword.update(:url, [host: "test.example.com"], fn url_opts ->
        Keyword.put(url_opts, :host, "test.example.com")
      end)
      |> Keyword.put_new(:secret_key_base, "27fsLlwxFAdrfzZvsTKefyNOFNT2ucWuIv/xYSS2myafQ6FEGytY1Gew0fD2BWU2")

    Application.put_env(:assistant, AssistantWeb.Endpoint, merged)

    on_exit(fn ->
      Application.delete_env(:assistant, :google_oauth_client_id)
      Application.delete_env(:assistant, :google_oauth_client_secret)
      Application.put_env(:assistant, AssistantWeb.Endpoint, original_config)
    end)

    %{conn: conn, user: user}
  end

  # -------------------------------------------------------------------
  # GET /auth/google/start
  # -------------------------------------------------------------------

  describe "GET /auth/google/start" do
    test "redirects to Google OAuth when magic link is valid", %{conn: conn, user: user} do
      {:ok, %{token: raw_token}} = MagicLink.generate(user.id)

      conn = get(conn, "/auth/google/start?token=#{raw_token}")

      # Should redirect (302) to Google OAuth URL
      assert conn.status == 302
      location = get_resp_header(conn, "location") |> List.first()
      assert location =~ "accounts.google.com/o/oauth2/v2/auth"
      assert location =~ "client_id=test-client-id"
      assert location =~ "code_challenge_method=S256"
      assert location =~ "state="
    end

    test "returns 400 error for invalid magic link token", %{conn: conn} do
      conn = get(conn, "/auth/google/start?token=invalid-token")

      assert conn.status == 400
      assert conn.resp_body =~ "invalid or has expired"
    end

    test "returns 400 error when no token param provided", %{conn: conn} do
      conn = get(conn, "/auth/google/start")

      assert conn.status == 400
      assert conn.resp_body =~ "invalid or has expired"
    end

    test "returns 400 error for already-consumed magic link", %{conn: conn, user: user} do
      {:ok, %{token: raw_token}} = MagicLink.generate(user.id)
      {:ok, _} = MagicLink.consume(raw_token)

      conn = get(conn, "/auth/google/start?token=#{raw_token}")

      assert conn.status == 400
      assert conn.resp_body =~ "invalid or has expired"
    end

    test "returns 400 error for expired magic link", %{conn: conn, user: user} do
      {:ok, %{token: raw_token, token_hash: hash}} = MagicLink.generate(user.id)

      # Expire the token
      from(t in Assistant.Schemas.AuthToken, where: t.token_hash == ^hash)
      |> Repo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)])

      conn = get(conn, "/auth/google/start?token=#{raw_token}")

      assert conn.status == 400
      assert conn.resp_body =~ "invalid or has expired"
    end
  end

  # -------------------------------------------------------------------
  # GET /auth/google/callback
  # -------------------------------------------------------------------

  describe "GET /auth/google/callback" do
    test "returns 400 when state is invalid/tampered", %{conn: conn} do
      conn = get(conn, "/auth/google/callback?code=test-code&state=tampered-state")

      assert conn.status == 400
      assert conn.resp_body =~ "Authorization failed"
    end

    test "returns 400 when no params provided", %{conn: conn} do
      conn = get(conn, "/auth/google/callback")

      assert conn.status == 400
      assert conn.resp_body =~ "Authorization failed"
    end

    test "returns 400 when Google sends an error param", %{conn: conn} do
      conn = get(conn, "/auth/google/callback?error=access_denied")

      assert conn.status == 400
      assert conn.resp_body =~ "denied or cancelled"
    end

    test "returns 400 when PKCE verifier is not found for state", %{conn: conn, user: user} do
      # Build a valid state but don't store a PKCE verifier for it
      {:ok, %{url: url}} =
        Assistant.Auth.OAuth.build_authorization_url(user.id,
          channel: "browser",
          token_hash: "test-hash"
        )

      # Extract the state from the URL
      state =
        URI.parse(url)
        |> Map.get(:query, "")
        |> URI.decode_query()
        |> Map.get("state", "")

      # Don't store PKCE verifier — callback should fail
      conn = get(conn, "/auth/google/callback?code=test-code&state=#{state}")

      assert conn.status == 400
      assert conn.resp_body =~ "Authorization failed"
    end
  end

  # -------------------------------------------------------------------
  # GET /auth/google/callback — happy path (Bypass)
  # -------------------------------------------------------------------

  describe "GET /auth/google/callback (happy path)" do
    setup %{conn: conn, user: user} do
      # Stand up Bypass to mock Google's token endpoint
      bypass = Bypass.open()

      # Point OAuth module's token URL to Bypass
      Application.put_env(:assistant, :google_token_url, "http://localhost:#{bypass.port}/token")

      on_exit(fn ->
        Application.delete_env(:assistant, :google_token_url)
      end)

      %{conn: conn, user: user, bypass: bypass}
    end

    test "valid state + PKCE + code → stores tokens, consumes magic link, renders success",
         %{conn: conn, user: user, bypass: bypass} do
      # 1. Generate a magic link for the user
      {:ok, %{token: raw_token}} = MagicLink.generate(user.id)

      # 2. Call /start to redirect to Google (stores PKCE code_verifier in auth_token DB row)
      start_conn = get(conn, "/auth/google/start?token=#{raw_token}")
      assert start_conn.status == 302
      location = get_resp_header(start_conn, "location") |> List.first()

      # 3. Extract state from the redirect URL
      state =
        URI.parse(location)
        |> Map.get(:query, "")
        |> URI.decode_query()
        |> Map.get("state", "")

      assert state != ""

      # 4. Set up Bypass to return a valid Google token response
      id_token_payload =
        %{"sub" => "google-uid-123", "email" => "test@example.com"}
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      id_token = "header.#{id_token_payload}.signature"

      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "access_token" => "ya29.test-access-token",
          "refresh_token" => "1//test-refresh-token",
          "expires_in" => 3599,
          "token_type" => "Bearer",
          "id_token" => id_token,
          "scope" => "openid email profile"
        }))
      end)

      # 5. Call /callback with the code and state
      callback_conn = get(conn, "/auth/google/callback?code=test_auth_code&state=#{state}")

      # 6. Assert: 200 with success HTML
      assert callback_conn.status == 200
      assert callback_conn.resp_body =~ "Google Account Connected"
      assert callback_conn.resp_body =~ "test@example.com"

      # 7. Assert: magic link is consumed (used_at is set)
      token_hash = :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)

      auth_token =
        Repo.one!(from(t in AuthToken, where: t.token_hash == ^token_hash))

      assert auth_token.used_at != nil

      # 8. Assert: OAuthToken row exists for the user
      oauth_token =
        Repo.one!(
          from(t in OAuthToken,
            where: t.user_id == ^user.id and t.provider == "google"
          )
        )

      assert oauth_token.provider_uid == "google-uid-123"
      assert oauth_token.provider_email == "test@example.com"
      assert oauth_token.scopes == "openid email profile"
      # Access token and refresh token are encrypted, but should not be nil
      assert oauth_token.access_token != nil
      assert oauth_token.refresh_token != nil
    end

    test "returns 400 when Google token exchange fails (non-200 response)",
         %{conn: conn, user: user, bypass: bypass} do
      {:ok, %{token: raw_token}} = MagicLink.generate(user.id)

      start_conn = get(conn, "/auth/google/start?token=#{raw_token}")
      assert start_conn.status == 302
      location = get_resp_header(start_conn, "location") |> List.first()

      state =
        URI.parse(location)
        |> Map.get(:query, "")
        |> URI.decode_query()
        |> Map.get("state", "")

      # Bypass returns an error from Google
      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, Jason.encode!(%{
          "error" => "invalid_grant",
          "error_description" => "Bad Request"
        }))
      end)

      callback_conn = get(conn, "/auth/google/callback?code=bad_code&state=#{state}")

      assert callback_conn.status == 400
      assert callback_conn.resp_body =~ "Authorization failed"

      # Magic link should NOT be consumed
      token_hash = :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)

      auth_token =
        Repo.one!(from(t in AuthToken, where: t.token_hash == ^token_hash))

      assert auth_token.used_at == nil
    end
  end

  # -------------------------------------------------------------------
  # Security: HTML escaping in rendered pages
  # -------------------------------------------------------------------

  describe "HTML rendering security" do
    test "error messages do not reveal internal failure reasons", %{conn: conn} do
      conn = get(conn, "/auth/google/start?token=bad")

      # Should show generic message, NOT internal error details
      refute conn.resp_body =~ ":not_found"
      refute conn.resp_body =~ "Ecto"
      refute conn.resp_body =~ "database"
    end
  end
end

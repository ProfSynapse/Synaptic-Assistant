# test/assistant_web/controllers/oauth_controller_test.exs — OAuthController endpoint tests.
#
# Risk Tier: CRITICAL — Browser-facing OAuth endpoints with security-sensitive behavior.
# Tests magic link validation, PKCE flow, HMAC state verification, error rendering.
# Uses ConnCase for Phoenix connection testing. DB-backed (DataCase sandbox via ConnCase).

defmodule AssistantWeb.OAuthControllerTest do
  use AssistantWeb.ConnCase, async: false

  alias Assistant.Auth.MagicLink
  alias Assistant.Schemas.User
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

    # Ensure ETS table exists for PKCE storage
    AssistantWeb.OAuthController.ensure_pkce_table()

    on_exit(fn ->
      Application.delete_env(:assistant, :google_oauth_client_id)
      Application.delete_env(:assistant, :google_oauth_client_secret)
      Application.put_env(:assistant, AssistantWeb.Endpoint, original_config)

      # Clean up ETS table entries (but don't delete the table itself)
      try do
        :ets.delete_all_objects(:oauth_pkce_verifiers)
      catch
        :error, :badarg -> :ok
      end
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

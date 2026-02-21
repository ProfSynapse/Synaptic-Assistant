defmodule AssistantWeb.OpenAIOAuthControllerTest do
  use AssistantWeb.ConnCase, async: false

  alias Assistant.Accounts

  setup do
    original_client_id = Application.get_env(:assistant, :openai_oauth_client_id)
    original_client_secret = Application.get_env(:assistant, :openai_oauth_client_secret)
    original_authorize_url = Application.get_env(:assistant, :openai_oauth_authorize_url)
    original_token_url = Application.get_env(:assistant, :openai_oauth_token_url)
    original_scope = Application.get_env(:assistant, :openai_oauth_scope)
    original_codex_compat = Application.get_env(:assistant, :openai_oauth_codex_compat)
    original_originator = Application.get_env(:assistant, :openai_oauth_originator)
    original_redirect_uri = Application.get_env(:assistant, :openai_oauth_redirect_uri)
    original_flow = Application.get_env(:assistant, :openai_oauth_flow)
    original_issuer = Application.get_env(:assistant, :openai_oauth_issuer)

    on_exit(fn ->
      restore_env(:openai_oauth_client_id, original_client_id)
      restore_env(:openai_oauth_client_secret, original_client_secret)
      restore_env(:openai_oauth_authorize_url, original_authorize_url)
      restore_env(:openai_oauth_token_url, original_token_url)
      restore_env(:openai_oauth_scope, original_scope)
      restore_env(:openai_oauth_codex_compat, original_codex_compat)
      restore_env(:openai_oauth_originator, original_originator)
      restore_env(:openai_oauth_redirect_uri, original_redirect_uri)
      restore_env(:openai_oauth_flow, original_flow)
      restore_env(:openai_oauth_issuer, original_issuer)
    end)

    :ok
  end

  describe "GET /settings_users/auth/openai (request)" do
    setup :register_and_log_in_settings_user

    test "redirects to OpenAI authorize URL with PKCE params", %{conn: conn} do
      Application.put_env(:assistant, :openai_oauth_flow, "browser")
      Application.put_env(:assistant, :openai_oauth_client_id, "test-openai-client")

      Application.put_env(
        :assistant,
        :openai_oauth_authorize_url,
        "https://openai.example/oauth/authorize"
      )

      Application.put_env(:assistant, :openai_oauth_scope, "openid profile email")

      conn = get(conn, ~p"/settings_users/auth/openai")

      location = redirected_to(conn)
      assert location =~ "https://openai.example/oauth/authorize?"
      assert location =~ "response_type=code"
      assert location =~ "client_id=test-openai-client"
      assert location =~ "redirect_uri="
      assert location =~ "scope=openid+profile+email"
      assert location =~ "state="
      assert location =~ "code_challenge="
      assert location =~ "code_challenge_method=S256"
      assert location =~ "id_token_add_organizations=true"
      assert location =~ "codex_cli_simplified_flow=true"
      assert location =~ "originator=synaptic-assistant"

      assert get_session(conn, :openai_oauth_state) |> is_binary()
      assert get_session(conn, :openai_pkce_verifier) |> is_binary()
    end

    test "falls back to default oauth client id when unset", %{conn: conn} do
      Application.put_env(:assistant, :openai_oauth_flow, "browser")
      Application.delete_env(:assistant, :openai_oauth_client_id)

      conn = get(conn, ~p"/settings_users/auth/openai")
      location = redirected_to(conn)
      assert location =~ "client_id=app_EMoamEEZ73f0CkXaXp7hrann"
    end

    test "stores popup flag when popup=1", %{conn: conn} do
      Application.put_env(:assistant, :openai_oauth_flow, "browser")
      conn = get(conn, ~p"/settings_users/auth/openai?popup=1")
      assert get_session(conn, :openai_oauth_popup) == true
    end

    test "defaults popup-only request to device flow", %{conn: conn} do
      bypass = Bypass.open()

      Application.put_env(:assistant, :openai_oauth_flow, "browser")
      Application.put_env(:assistant, :openai_oauth_issuer, "http://localhost:#{bypass.port}")

      Bypass.expect_once(bypass, "POST", "/api/accounts/deviceauth/usercode", fn bp_conn ->
        bp_conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "device_auth_id" => "popup-dev-auth-id",
            "user_code" => "WXYZ-1234",
            "interval" => "5"
          })
        )
      end)

      conn = get(conn, ~p"/settings_users/auth/openai?popup=1")

      body = html_response(conn, 200)
      assert body =~ "Connect OpenAI"
      assert body =~ "WXYZ-1234"
      assert get_session(conn, :openai_device_auth_id) == "popup-dev-auth-id"
      assert get_session(conn, :openai_oauth_popup) == true
    end

    test "renders device flow page when flow=device", %{conn: conn} do
      bypass = Bypass.open()

      Application.put_env(:assistant, :openai_oauth_issuer, "http://localhost:#{bypass.port}")

      Bypass.expect_once(bypass, "POST", "/api/accounts/deviceauth/usercode", fn bp_conn ->
        bp_conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "device_auth_id" => "dev-auth-id",
            "user_code" => "ABCD-EFGH",
            "interval" => "5"
          })
        )
      end)

      conn = get(conn, ~p"/settings_users/auth/openai?popup=1&flow=device")

      body = html_response(conn, 200)
      assert body =~ "Connect OpenAI"
      assert body =~ "ABCD-EFGH"
      assert body =~ "/settings_users/auth/openai/device/poll"
      assert get_session(conn, :openai_device_auth_id) == "dev-auth-id"
    end
  end

  describe "GET /settings_users/auth/openai (request, unauthenticated)" do
    test "redirects to login", %{conn: conn} do
      Application.put_env(:assistant, :openai_oauth_client_id, "test-openai-client")

      conn = get(conn, ~p"/settings_users/auth/openai")

      assert redirected_to(conn) == ~p"/settings_users/log-in"
    end
  end

  describe "GET /settings_users/auth/openai/callback (happy path)" do
    setup :register_and_log_in_settings_user

    test "exchanges code, stores access token, and links user", %{
      conn: conn,
      settings_user: settings_user
    } do
      bypass = Bypass.open()

      Application.put_env(:assistant, :openai_oauth_client_id, "test-openai-client")
      Application.put_env(:assistant, :openai_oauth_client_secret, "test-openai-secret")

      Application.put_env(
        :assistant,
        :openai_oauth_token_url,
        "http://localhost:#{bypass.port}/oauth/token"
      )

      Bypass.expect_once(bypass, "POST", "/oauth/token", fn bp_conn ->
        {:ok, body, bp_conn} = Plug.Conn.read_body(bp_conn)
        decoded = URI.decode_query(body)

        assert decoded["grant_type"] == "authorization_code"
        assert decoded["code"] == "test-auth-code"
        assert decoded["code_verifier"] == "test-verifier"
        assert decoded["client_id"] == "test-openai-client"
        assert decoded["client_secret"] == "test-openai-secret"

        account_claims = %{
          "https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct_test"}
        }

        id_token = fake_jwt(account_claims)

        bp_conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "openai-oauth-access-token",
            "refresh_token" => "openai-oauth-refresh-token",
            "id_token" => id_token,
            "expires_in" => 3600
          })
        )
      end)

      conn =
        conn
        |> put_session(:openai_oauth_state, "test-state")
        |> put_session(:openai_pkce_verifier, "test-verifier")
        |> get(~p"/settings_users/auth/openai/callback?code=test-auth-code&state=test-state")

      assert redirected_to(conn) == ~p"/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "OpenAI connected successfully."

      refute get_session(conn, :openai_oauth_state)
      refute get_session(conn, :openai_pkce_verifier)

      reloaded = Accounts.get_settings_user!(settings_user.id)
      assert reloaded.openai_api_key == "openai-oauth-access-token"
      assert reloaded.openai_refresh_token == "openai-oauth-refresh-token"
      assert reloaded.openai_account_id == "acct_test"
      assert reloaded.openai_auth_type == "oauth"
      assert %DateTime{} = reloaded.openai_expires_at
      assert is_binary(reloaded.user_id)
    end

    test "returns popup-closing HTML when request started in popup", %{conn: conn} do
      bypass = Bypass.open()

      Application.put_env(:assistant, :openai_oauth_client_id, "test-openai-client")
      Application.put_env(:assistant, :openai_oauth_client_secret, "test-openai-secret")

      Application.put_env(
        :assistant,
        :openai_oauth_token_url,
        "http://localhost:#{bypass.port}/oauth/token"
      )

      Bypass.expect_once(bypass, "POST", "/oauth/token", fn bp_conn ->
        bp_conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"access_token" => "popup-access-token"}))
      end)

      conn =
        conn
        |> put_session(:openai_oauth_state, "test-state")
        |> put_session(:openai_pkce_verifier, "test-verifier")
        |> put_session(:openai_oauth_popup, true)
        |> get(~p"/settings_users/auth/openai/callback?code=test-auth-code&state=test-state")

      assert html_response(conn, 200) =~ "This window will close automatically."
      assert html_response(conn, 200) =~ "OpenAI Connected"
      refute get_session(conn, :openai_oauth_popup)
    end
  end

  describe "GET /settings_users/auth/openai/callback (error paths)" do
    setup :register_and_log_in_settings_user

    test "rejects invalid state", %{conn: conn} do
      Application.put_env(:assistant, :openai_oauth_client_id, "test-openai-client")

      conn =
        conn
        |> put_session(:openai_oauth_state, "expected-state")
        |> put_session(:openai_pkce_verifier, "test-verifier")
        |> get(~p"/settings_users/auth/openai/callback?code=test-auth-code&state=wrong-state")

      assert redirected_to(conn) == ~p"/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "OpenAI connection failed. Please try again."
    end

    test "handles provider cancellation", %{conn: conn} do
      conn = get(conn, ~p"/settings_users/auth/openai/callback?error=access_denied")

      assert redirected_to(conn) == ~p"/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "OpenAI connection was cancelled."
    end
  end

  describe "GET /settings_users/auth/openai/callback (unauthenticated)" do
    test "redirects to login", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{openai_oauth_state: "state", openai_pkce_verifier: "verifier"})
        |> get(~p"/settings_users/auth/openai/callback?code=test-code&state=state")

      assert redirected_to(conn) == ~p"/settings_users/log-in"
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:assistant, key)
  defp restore_env(key, value), do: Application.put_env(:assistant, key, value)

  defp fake_jwt(payload) when is_map(payload) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "none", "typ" => "JWT"}), padding: false)
    body = Base.url_encode64(Jason.encode!(payload), padding: false)
    "#{header}.#{body}.sig"
  end
end

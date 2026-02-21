# test/assistant_web/controllers/openrouter_oauth_controller_test.exs
#
# Tests for the OpenRouter PKCE OAuth controller.
# Covers request (initiation) and callback (code exchange) flows.
# Uses Bypass to mock OpenRouter's key exchange endpoint.
#
# Related files:
#   - lib/assistant_web/controllers/openrouter_oauth_controller.ex (module under test)
#   - lib/assistant/accounts.ex (save/delete openrouter_api_key)
#   - test/support/conn_case.ex (register_and_log_in_settings_user helper)

defmodule AssistantWeb.OpenRouterOAuthControllerTest do
  # async: false — modifies global Application env for openrouter_keys_url.
  use AssistantWeb.ConnCase, async: false

  alias Assistant.Accounts

  # ---------------------------------------------------------------
  # Setup — Application env save/restore + Bypass for key exchange
  # ---------------------------------------------------------------

  setup do
    original_keys_url = Application.get_env(:assistant, :openrouter_keys_url)

    on_exit(fn ->
      if is_nil(original_keys_url) do
        Application.delete_env(:assistant, :openrouter_keys_url)
      else
        Application.put_env(:assistant, :openrouter_keys_url, original_keys_url)
      end
    end)

    :ok
  end

  defp configure_bypass do
    bypass = Bypass.open()

    Application.put_env(
      :assistant,
      :openrouter_keys_url,
      "http://localhost:#{bypass.port}/api/v1/auth/keys"
    )

    bypass
  end

  # ---------------------------------------------------------------
  # GET /settings_users/auth/openrouter — request/2
  # ---------------------------------------------------------------

  describe "GET /settings_users/auth/openrouter (request)" do
    setup :register_and_log_in_settings_user

    test "redirects to OpenRouter with PKCE params when authenticated", %{
      conn: conn
    } do
      conn = get(conn, ~p"/settings_users/auth/openrouter")

      location = redirected_to(conn)
      assert location =~ "https://openrouter.ai/auth?"
      assert location =~ "callback_url="
      assert location =~ "code_challenge="
      assert location =~ "code_challenge_method=S256"

      # Verify PKCE verifier stored in session
      assert get_session(conn, :openrouter_pkce_verifier) |> is_binary()
      assert get_session(conn, :openrouter_pkce_verifier) != ""
    end
  end

  describe "GET /settings_users/auth/openrouter (request, unauthenticated)" do
    test "redirects to login when not authenticated", %{conn: conn} do
      conn = get(conn, ~p"/settings_users/auth/openrouter")

      assert redirected_to(conn) == ~p"/settings_users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must log in to connect OpenRouter."
    end
  end

  # ---------------------------------------------------------------
  # GET /settings_users/auth/openrouter/callback — callback/2
  # ---------------------------------------------------------------

  describe "GET /settings_users/auth/openrouter/callback (happy path)" do
    setup :register_and_log_in_settings_user

    test "exchanges code, stores API key, and redirects to settings", %{
      conn: conn,
      settings_user: settings_user
    } do
      bypass = configure_bypass()

      Bypass.expect_once(bypass, "POST", "/api/v1/auth/keys", fn bp_conn ->
        {:ok, body, bp_conn} = Plug.Conn.read_body(bp_conn)
        decoded = Jason.decode!(body)
        assert decoded["code"] == "test-auth-code"
        assert decoded["code_verifier"] == "test-verifier-value"
        assert decoded["code_challenge_method"] == "S256"

        # No Authorization header should be present
        auth_header = Plug.Conn.get_req_header(bp_conn, "authorization")
        assert auth_header == []

        bp_conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"key" => "sk-or-test-key-123"}))
      end)

      conn =
        conn
        |> put_session(:openrouter_pkce_verifier, "test-verifier-value")
        |> get(~p"/settings_users/auth/openrouter/callback?code=test-auth-code")

      assert redirected_to(conn) == ~p"/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "OpenRouter connected successfully."

      # Verify PKCE verifier cleared from session
      refute get_session(conn, :openrouter_pkce_verifier)

      # Verify API key persisted to DB
      reloaded = Accounts.get_settings_user!(settings_user.id)
      assert reloaded.openrouter_api_key == "sk-or-test-key-123"
    end
  end

  describe "GET /settings_users/auth/openrouter/callback (error paths)" do
    setup :register_and_log_in_settings_user

    test "redirects to settings when PKCE verifier missing from session", %{conn: conn} do
      # No verifier in session — simulate direct callback hit
      conn = get(conn, ~p"/settings_users/auth/openrouter/callback?code=test-code")

      assert redirected_to(conn) == ~p"/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "OpenRouter connection failed. Please try again."
    end

    test "redirects to settings when code exchange returns non-200", %{conn: conn} do
      bypass = configure_bypass()

      Bypass.expect_once(bypass, "POST", "/api/v1/auth/keys", fn bp_conn ->
        bp_conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(401, Jason.encode!(%{"error" => "invalid_code"}))
      end)

      conn =
        conn
        |> put_session(:openrouter_pkce_verifier, "test-verifier")
        |> get(~p"/settings_users/auth/openrouter/callback?code=expired-code")

      assert redirected_to(conn) == ~p"/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Failed to connect OpenRouter. Please try again."
    end

    test "redirects to settings when code exchange returns unexpected body", %{conn: conn} do
      bypass = configure_bypass()

      Bypass.expect_once(bypass, "POST", "/api/v1/auth/keys", fn bp_conn ->
        bp_conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"something" => "unexpected"}))
      end)

      conn =
        conn
        |> put_session(:openrouter_pkce_verifier, "test-verifier")
        |> get(~p"/settings_users/auth/openrouter/callback?code=valid-code")

      assert redirected_to(conn) == ~p"/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Failed to connect OpenRouter. Please try again."
    end

    test "redirects to settings when code exchange HTTP request fails", %{conn: conn} do
      bypass = configure_bypass()

      Bypass.down(bypass)

      conn =
        conn
        |> put_session(:openrouter_pkce_verifier, "test-verifier")
        |> get(~p"/settings_users/auth/openrouter/callback?code=some-code")

      assert redirected_to(conn) == ~p"/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Failed to connect OpenRouter. Please try again."
    end

    test "handles missing code param (cancellation)", %{conn: conn} do
      conn =
        conn
        |> put_session(:openrouter_pkce_verifier, "test-verifier")
        |> get(~p"/settings_users/auth/openrouter/callback")

      assert redirected_to(conn) == ~p"/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "OpenRouter connection was cancelled or failed."

      # Verify verifier cleaned up
      refute get_session(conn, :openrouter_pkce_verifier)
    end
  end

  describe "GET /settings_users/auth/openrouter/callback (unauthenticated)" do
    test "redirects to login when not authenticated", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{openrouter_pkce_verifier: "test-verifier"})
        |> get(~p"/settings_users/auth/openrouter/callback?code=test-code")

      assert redirected_to(conn) == ~p"/settings_users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must log in to connect OpenRouter."
    end
  end
end

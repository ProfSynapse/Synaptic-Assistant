# test/assistant_web/controllers/openrouter_oauth_controller_test.exs
#
# Tests for the OpenRouter PKCE OAuth controller.
# Covers request (initiation), callback (code exchange), and disconnect flows.
# Uses Bypass to mock OpenRouter's key exchange endpoint.
#
# Related files:
#   - lib/assistant_web/controllers/openrouter_oauth_controller.ex (module under test)
#   - lib/assistant/accounts.ex (save/delete openrouter_api_key)
#   - test/support/conn_case.ex (register_and_log_in_settings_user helper)

defmodule AssistantWeb.OpenRouterOAuthControllerTest do
  # async: false — modifies global Application env for openrouter_app_api_key.
  use AssistantWeb.ConnCase, async: false

  alias Assistant.Accounts

  # ---------------------------------------------------------------
  # Setup — Application env save/restore + Bypass for key exchange
  # ---------------------------------------------------------------

  setup do
    original_app_key = Application.get_env(:assistant, :openrouter_app_api_key)
    original_keys_url = Application.get_env(:assistant, :openrouter_keys_url)

    on_exit(fn ->
      if is_nil(original_app_key) do
        Application.delete_env(:assistant, :openrouter_app_api_key)
      else
        Application.put_env(:assistant, :openrouter_app_api_key, original_app_key)
      end

      if is_nil(original_keys_url) do
        Application.delete_env(:assistant, :openrouter_keys_url)
      else
        Application.put_env(:assistant, :openrouter_keys_url, original_keys_url)
      end
    end)

    :ok
  end

  defp configure_app_key do
    Application.put_env(:assistant, :openrouter_app_api_key, "test-app-api-key")
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

    test "redirects to OpenRouter with PKCE params when authenticated and configured", %{
      conn: conn
    } do
      configure_app_key()

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

    test "redirects to settings when OPENROUTER_APP_API_KEY not configured", %{conn: conn} do
      Application.delete_env(:assistant, :openrouter_app_api_key)

      conn = get(conn, ~p"/settings_users/auth/openrouter")

      assert redirected_to(conn) == ~p"/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "OpenRouter integration is not configured."
    end
  end

  describe "GET /settings_users/auth/openrouter (request, unauthenticated)" do
    test "redirects to login when not authenticated", %{conn: conn} do
      configure_app_key()

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
      configure_app_key()
      bypass = configure_bypass()

      Bypass.expect_once(bypass, "POST", "/api/v1/auth/keys", fn bp_conn ->
        {:ok, body, bp_conn} = Plug.Conn.read_body(bp_conn)
        decoded = Jason.decode!(body)
        assert decoded["code"] == "test-auth-code"

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
      configure_app_key()

      # No verifier in session — simulate direct callback hit
      conn = get(conn, ~p"/settings_users/auth/openrouter/callback?code=test-code")

      assert redirected_to(conn) == ~p"/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "OpenRouter connection failed. Please try again."
    end

    test "redirects to settings when code exchange returns non-200", %{conn: conn} do
      configure_app_key()
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
      configure_app_key()
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
      configure_app_key()
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

  # ---------------------------------------------------------------
  # DELETE /settings_users/auth/openrouter — disconnect/2
  # ---------------------------------------------------------------

  describe "DELETE /settings_users/auth/openrouter (disconnect)" do
    setup :register_and_log_in_settings_user

    test "removes API key and redirects to settings", %{
      conn: conn,
      settings_user: settings_user
    } do
      # Pre-set an API key
      {:ok, _} = Accounts.save_openrouter_api_key(settings_user, "sk-or-existing-key")
      assert Accounts.openrouter_connected?(Accounts.get_settings_user!(settings_user.id))

      conn = delete(conn, ~p"/settings_users/auth/openrouter")

      assert redirected_to(conn) == ~p"/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "OpenRouter disconnected."

      # Verify key removed from DB
      reloaded = Accounts.get_settings_user!(settings_user.id)
      refute Accounts.openrouter_connected?(reloaded)
    end

    test "succeeds even when no API key was stored", %{conn: conn, settings_user: settings_user} do
      refute Accounts.openrouter_connected?(settings_user)

      conn = delete(conn, ~p"/settings_users/auth/openrouter")

      assert redirected_to(conn) == ~p"/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "OpenRouter disconnected."
    end
  end

  describe "DELETE /settings_users/auth/openrouter (unauthenticated)" do
    test "redirects to login when not authenticated", %{conn: conn} do
      conn = delete(conn, ~p"/settings_users/auth/openrouter")

      assert redirected_to(conn) == ~p"/settings_users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must log in to disconnect OpenRouter."
    end
  end
end

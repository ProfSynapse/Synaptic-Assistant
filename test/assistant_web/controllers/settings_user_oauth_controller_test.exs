defmodule AssistantWeb.SettingsUserOAuthControllerTest do
  use AssistantWeb.ConnCase, async: false

  setup do
    original_client_id = Application.get_env(:assistant, :google_oauth_client_id)
    original_client_secret = Application.get_env(:assistant, :google_oauth_client_secret)

    on_exit(fn ->
      if is_nil(original_client_id) do
        Application.delete_env(:assistant, :google_oauth_client_id)
      else
        Application.put_env(:assistant, :google_oauth_client_id, original_client_id)
      end

      if is_nil(original_client_secret) do
        Application.delete_env(:assistant, :google_oauth_client_secret)
      else
        Application.put_env(:assistant, :google_oauth_client_secret, original_client_secret)
      end
    end)

    :ok
  end

  describe "GET /settings_users/auth/google" do
    test "redirects to login when OAuth client id is missing", %{conn: conn} do
      Application.delete_env(:assistant, :google_oauth_client_id)

      conn = get(conn, ~p"/settings_users/auth/google")

      assert redirected_to(conn) == ~p"/settings_users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Google sign in is not configured yet."
    end

    test "redirects to Google authorization endpoint when configured", %{conn: conn} do
      Application.put_env(:assistant, :google_oauth_client_id, "test-client-id")

      conn = get(conn, ~p"/settings_users/auth/google")

      assert redirected_to(conn) =~ "https://accounts.google.com/o/oauth2/v2/auth?"
      assert get_session(conn, :settings_user_google_oauth_state)
    end
  end

  describe "GET /settings_users/auth/google/callback" do
    test "rejects callback when state does not match", %{conn: conn} do
      Application.put_env(:assistant, :google_oauth_client_id, "test-client-id")
      Application.put_env(:assistant, :google_oauth_client_secret, "test-client-secret")

      conn =
        conn
        |> init_test_session(settings_user_google_oauth_state: "expected")
        |> get(~p"/settings_users/auth/google/callback?code=abc&state=wrong")

      assert redirected_to(conn) == ~p"/settings_users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Google sign in failed. Please try again."
    end

    test "handles provider cancellation", %{conn: conn} do
      conn = get(conn, ~p"/settings_users/auth/google/callback?error=access_denied")

      assert redirected_to(conn) == ~p"/settings_users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Google sign in was cancelled."
    end
  end
end

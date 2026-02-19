defmodule AssistantWeb.SettingsUserSessionController do
  use AssistantWeb, :controller

  alias Assistant.Accounts
  alias AssistantWeb.SettingsUserAuth

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "Settings user confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # magic link login
  defp create(conn, %{"settings_user" => %{"token" => token} = settings_user_params}, info) do
    case Accounts.login_settings_user_by_magic_link(token) do
      {:ok, {settings_user, tokens_to_disconnect}} ->
        SettingsUserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> SettingsUserAuth.log_in_settings_user(settings_user, settings_user_params)

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/settings_users/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"settings_user" => settings_user_params}, info) do
    %{"email" => email, "password" => password} = settings_user_params

    if settings_user = Accounts.get_settings_user_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, info)
      |> SettingsUserAuth.log_in_settings_user(settings_user, settings_user_params)
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/settings_users/log-in")
    end
  end

  def update_password(conn, %{"settings_user" => settings_user_params} = params) do
    settings_user = conn.assigns.current_scope.settings_user
    true = Accounts.sudo_mode?(settings_user)

    {:ok, {_settings_user, expired_tokens}} =
      Accounts.update_settings_user_password(settings_user, settings_user_params)

    # disconnect all existing LiveViews with old sessions
    SettingsUserAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:settings_user_return_to, ~p"/settings_users/settings")
    |> create(params, "Password updated successfully!")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> SettingsUserAuth.log_out_settings_user()
  end
end

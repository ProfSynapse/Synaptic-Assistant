defmodule AssistantWeb.ImpersonationController do
  use AssistantWeb, :controller

  alias Assistant.Accounts
  alias AssistantWeb.SettingsUserAuth

  @doc """
  Starts impersonating the target user. Admin-only.
  Super admins can impersonate anyone; team admins can only impersonate users in their team.
  """
  def create(conn, %{"id" => target_user_id}) do
    admin = conn.assigns.current_scope.settings_user

    cond do
      !admin || !admin.is_admin ->
        conn
        |> put_flash(:error, "Not authorized.")
        |> redirect(to: ~p"/settings")

      admin.id == target_user_id ->
        conn
        |> put_flash(:error, "You cannot impersonate yourself.")
        |> redirect(to: ~p"/settings/admin")

      true ->
        case Accounts.get_settings_user(target_user_id) do
          nil ->
            conn
            |> put_flash(:error, "User not found.")
            |> redirect(to: ~p"/settings/admin")

          target_user ->
            cond do
              Accounts.settings_user_disabled?(target_user) ->
                conn
                |> put_flash(:error, "Cannot impersonate a disabled user.")
                |> redirect(to: ~p"/settings/admin")

              not admin.is_super_admin and admin.team_id != target_user.team_id ->
                conn
                |> put_flash(:error, "You can only impersonate users in your team.")
                |> redirect(to: ~p"/settings/admin")

              true ->
                conn
                |> put_flash(:info, "Now viewing as #{target_user.email}.")
                |> SettingsUserAuth.impersonate_user(target_user)
            end
        end
    end
  end

  @doc """
  Stops impersonating and returns to the admin's own session.
  """
  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Returned to your admin account.")
    |> SettingsUserAuth.stop_impersonating()
  end
end

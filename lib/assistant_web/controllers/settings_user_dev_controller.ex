defmodule AssistantWeb.SettingsUserDevController do
  use AssistantWeb, :controller

  alias Assistant.Accounts
  alias Assistant.Accounts.SettingsUser
  alias Assistant.Repo
  alias AssistantWeb.SettingsUserAuth

  @default_dev_email "dev@synaptic-assistant.local"

  def quick_login(conn, params) do
    email = params["email"] || @default_dev_email

    with {:ok, %SettingsUser{} = settings_user} <- fetch_or_create_settings_user(email),
         %SettingsUser{} = confirmed_user <- ensure_confirmed(settings_user) do
      conn
      |> put_flash(:info, "Dev login as #{confirmed_user.email}")
      |> SettingsUserAuth.log_in_settings_user(confirmed_user, %{"remember_me" => "true"})
    else
      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_flash(:error, "Could not create dev login user. Check the email format.")
        |> redirect(to: ~p"/settings_users/log-in")
    end
  end

  defp fetch_or_create_settings_user(email) do
    case Accounts.get_settings_user_by_email(email) do
      %SettingsUser{} = settings_user ->
        {:ok, settings_user}

      nil ->
        Accounts.register_settings_user(%{"email" => email})
    end
  end

  defp ensure_confirmed(%SettingsUser{confirmed_at: nil} = settings_user) do
    settings_user
    |> SettingsUser.confirm_changeset()
    |> Repo.update!()
  end

  defp ensure_confirmed(%SettingsUser{} = settings_user), do: settings_user
end

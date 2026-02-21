defmodule AssistantWeb.SettingsLive.Context do
  @moduledoc false

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Assistant.Accounts.Scope

  def current_settings_user(socket) do
    case socket.assigns[:current_scope] do
      %Scope{settings_user: settings_user} -> settings_user
      _ -> nil
    end
  end

  def current_user_id(socket) do
    case current_settings_user(socket) do
      %{user_id: user_id} when not is_nil(user_id) -> user_id
      _ -> nil
    end
  end

  def with_settings_user(socket, callback) when is_function(callback, 1) do
    case current_settings_user(socket) do
      nil -> {:noreply, put_flash(socket, :error, "You must be logged in.")}
      settings_user -> callback.(settings_user)
    end
  end

  # If the settings_user already has a linked chat user, return it.
  # Otherwise auto-create a users record and bridge it, so the OAuth
  # token has somewhere to live for chat-initiated Google skills.
  def ensure_linked_user(%{user_id: user_id}) when not is_nil(user_id), do: {:ok, user_id}

  def ensure_linked_user(settings_user) do
    user_attrs = %{
      external_id: "settings:#{settings_user.id}",
      channel: "settings",
      display_name: settings_user.display_name
    }

    case %Assistant.Schemas.User{}
         |> Assistant.Schemas.User.changeset(user_attrs)
         |> Assistant.Repo.insert() do
      {:ok, user} ->
        settings_user
        |> Ecto.Changeset.change(user_id: user.id)
        |> Assistant.Repo.update()
        |> case do
          {:ok, _} -> {:ok, user.id}
          {:error, changeset} -> {:error, changeset}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def with_linked_user(socket, callback) when is_function(callback, 2) do
    case current_settings_user(socket) do
      nil ->
        {:noreply, put_flash(socket, :error, "You must be logged in.")}

      %{user_id: user_id} = settings_user when not is_nil(user_id) ->
        callback.(settings_user, user_id)

      _settings_user ->
        {:noreply, put_flash(socket, :error, "No linked user account.")}
    end
  end
end

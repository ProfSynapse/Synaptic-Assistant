defmodule AssistantWeb.SettingsLive.Context do
  @moduledoc false

  import Ecto.Query, warn: false
  import Phoenix.LiveView, only: [put_flash: 3]

  require Logger

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
  # Otherwise try to link to an existing chat user before falling back
  # to creating a "settings" pseudo-user. In single-user setups (only
  # one non-settings chat user exists), auto-link to that user so OAuth
  # keys resolve correctly across channels.
  def ensure_linked_user(%{user_id: user_id}) when not is_nil(user_id), do: {:ok, user_id}

  def ensure_linked_user(settings_user) do
    chat_users =
      from(u in Assistant.Schemas.User,
        where: u.channel != "settings" or is_nil(u.channel),
        select: u
      )
      |> Assistant.Repo.all()

    case chat_users do
      [single_user] ->
        # Single-user setup: auto-link to the existing chat user
        link_settings_user(settings_user, single_user.id)

      [_ | _] ->
        # Multiple chat users: create pseudo-user (safe default)
        Logger.info(
          "ensure_linked_user: #{length(chat_users)} chat users exist; " <>
            "creating settings pseudo-user. Consider manually linking " <>
            "settings_user #{settings_user.id} to the correct chat user."
        )

        create_pseudo_user(settings_user)

      [] ->
        # No chat users yet (first-time setup): create pseudo-user
        create_pseudo_user(settings_user)
    end
  end

  defp link_settings_user(settings_user, user_id) do
    settings_user
    |> Ecto.Changeset.change(user_id: user_id)
    |> Assistant.Repo.update()
    |> case do
      {:ok, _} -> {:ok, user_id}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp create_pseudo_user(settings_user) do
    user_attrs = %{
      external_id: "settings:#{settings_user.id}",
      channel: "settings",
      display_name: settings_user.display_name
    }

    case %Assistant.Schemas.User{}
         |> Assistant.Schemas.User.changeset(user_attrs)
         |> Assistant.Repo.insert() do
      {:ok, user} ->
        link_settings_user(settings_user, user.id)

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

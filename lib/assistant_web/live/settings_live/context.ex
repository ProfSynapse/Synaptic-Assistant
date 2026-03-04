defmodule AssistantWeb.SettingsLive.Context do
  @moduledoc false

  import Ecto.Query, warn: false
  import Phoenix.LiveView, only: [put_flash: 3]

  require Logger

  alias Assistant.Accounts.Scope
  alias Assistant.Repo
  alias Assistant.Schemas.User

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

  # If the settings_user has a real (non-settings) linked chat user, return it.
  # If linked to a "settings" pseudo-user (legacy/broken state), attempt repair:
  # when exactly one real chat user exists, re-link to that user.
  # Otherwise preserve the pseudo link to avoid unsafe guessing.
  def ensure_linked_user(%{user_id: user_id} = settings_user) when not is_nil(user_id) do
    case Repo.get(User, user_id) do
      %User{channel: channel} when channel != "settings" ->
        {:ok, user_id}

      _ ->
        repair_or_create_link(settings_user)
    end
  end

  def ensure_linked_user(settings_user), do: repair_or_create_link(settings_user)

  defp repair_or_create_link(settings_user) do
    chat_users =
      from(u in User,
        where: u.channel != "settings" or is_nil(u.channel),
        select: u
      )
      |> Repo.all()

    case chat_users do
      [single_user] ->
        # Single-user setup: auto-link to the existing chat user
        link_settings_user(settings_user, single_user.id)

      [_ | _] ->
        # Multiple chat users: do not guess. Keep existing pseudo link if present,
        # otherwise create a pseudo user as a safe default.
        if linked_to_pseudo_user?(settings_user.user_id) do
          {:ok, settings_user.user_id}
        else
          Logger.info(
            "ensure_linked_user: #{length(chat_users)} chat users exist; " <>
              "creating settings pseudo-user. Consider manually linking " <>
              "settings_user #{settings_user.id} to the correct chat user."
          )

          create_pseudo_user(settings_user)
        end

      [] ->
        # No chat users yet (first-time setup): keep existing pseudo link if present,
        # otherwise create one.
        if linked_to_pseudo_user?(settings_user.user_id) do
          {:ok, settings_user.user_id}
        else
          create_pseudo_user(settings_user)
        end
    end
  end

  defp link_settings_user(settings_user, user_id) do
    settings_user
    |> Ecto.Changeset.change(user_id: user_id)
    |> Repo.update()
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

    case %User{}
         |> User.changeset(user_attrs)
         |> Repo.insert() do
      {:ok, user} ->
        link_settings_user(settings_user, user.id)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp linked_to_pseudo_user?(user_id) when is_binary(user_id) do
    match?(%User{channel: "settings"}, Repo.get(User, user_id))
  end

  defp linked_to_pseudo_user?(_), do: false

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

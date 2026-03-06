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

  # Identity Resolution State Machine (email-based matching):
  #
  # settings_user logs in -> ensure_linked_user:
  #   +-- user_id -> real user (channel != "settings") -> DONE
  #   +-- user_id -> pseudo-user (channel = "settings") -> email match?
  #   |   +-- YES: upgrade (re-link to real user, migrate conversations) -> DONE
  #   |   +-- NO:  keep pseudo-user (no chat user with this email yet)
  #   +-- user_id is nil -> email match?
  #       +-- YES: link to matched user -> DONE
  #       +-- NO:  create pseudo-user (first-time, no chat user yet)
  def ensure_linked_user(%{user_id: user_id} = settings_user) when not is_nil(user_id) do
    case Repo.get(User, user_id) do
      %User{channel: "settings"} ->
        # Linked to a pseudo-user — try to upgrade via email match
        try_email_upgrade(settings_user)

      %User{channel: "settings:archived"} ->
        # Linked to an archived pseudo-user — try email match fresh
        try_email_link(settings_user)

      %User{} ->
        # Linked to a real user — done
        {:ok, user_id}

      nil ->
        # Stale reference — try email match
        try_email_link(settings_user)
    end
  end

  def ensure_linked_user(settings_user), do: try_email_link(settings_user)

  # Attempt to upgrade from a pseudo-user to a real user via email match
  defp try_email_upgrade(settings_user) do
    case find_real_user_by_email(settings_user.email) do
      {:ok, real_user_id} ->
        # Found a real user with matching email — upgrade
        case Assistant.Channels.UserResolver.upgrade_pseudo_user(
               settings_user.user_id,
               real_user_id
             ) do
          {:ok, _} ->
            # Also update the settings_user link (upgrade_pseudo_user handles this,
            # but be explicit for the in-memory value)
            {:ok, real_user_id}

          {:error, reason} ->
            Logger.warning("Failed to upgrade pseudo-user",
              settings_user_id: settings_user.id,
              pseudo_user_id: settings_user.user_id,
              error: inspect(reason)
            )

            # Fall back to keeping the pseudo-user
            {:ok, settings_user.user_id}
        end

      :not_found ->
        # No matching real user yet — keep pseudo-user
        {:ok, settings_user.user_id}
    end
  end

  # Attempt to link directly to a real user by email, or create a pseudo-user
  defp try_email_link(settings_user) do
    case find_real_user_by_email(settings_user.email) do
      {:ok, real_user_id} ->
        link_settings_user(settings_user, real_user_id)

      :not_found ->
        # No matching real user — create a pseudo-user
        create_pseudo_user(settings_user)
    end
  end

  # Find a real (non-pseudo) user by email
  defp find_real_user_by_email(nil), do: :not_found

  defp find_real_user_by_email(email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()

    if normalized == "" do
      :not_found
    else
      query =
        from u in User,
          where: fragment("lower(?)", u.email) == ^normalized,
          where: u.channel != "settings" or is_nil(u.channel),
          select: u.id,
          limit: 1

      case Repo.one(query) do
        nil -> :not_found
        user_id -> {:ok, user_id}
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

defmodule AssistantWeb.SettingsLive.Profile do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [push_event: 3, put_flash: 3]

  alias Assistant.Accounts
  alias Assistant.Accounts.Scope
  alias AssistantWeb.SettingsLive.Context
  alias AssistantWeb.SettingsLive.Loaders

  def save_profile(socket, params, opts) do
    flash? = Keyword.get(opts, :flash?, false)
    merged_profile = merge_profile_params(socket.assigns.profile, params)

    socket =
      socket
      |> assign(:profile, merged_profile)
      |> assign(:profile_form, to_form(merged_profile, as: :profile))
      |> notify_autosave("saving", "Saving profile...")

    case Context.current_settings_user(socket) do
      nil ->
        socket =
          socket
          |> notify_autosave("error", "Could not save profile")
          |> maybe_put_profile_flash(
            flash?,
            :error,
            "You must be logged in to update profile settings"
          )

        {:noreply, socket}

      settings_user ->
        case Accounts.update_settings_user_profile(settings_user, merged_profile) do
          {:ok, updated_user} ->
            socket =
              socket
              |> assign(:current_scope, Scope.for_settings_user(updated_user))
              |> Loaders.load_profile()
              |> notify_autosave("saved", "All changes saved")
              |> maybe_put_profile_flash(flash?, :info, "Profile updated")

            {:noreply, socket}

          {:error, %Ecto.Changeset{} = changeset} ->
            message = format_changeset_errors(changeset)

            socket =
              socket
              |> notify_autosave("error", "Could not save profile")
              |> maybe_put_profile_flash(flash?, :error, "Failed to save profile: #{message}")

            {:noreply, socket}

          {:error, reason} ->
            message = inspect(reason)

            socket =
              socket
              |> notify_autosave("error", "Could not save profile")
              |> maybe_put_profile_flash(flash?, :error, "Failed to save profile: #{message}")

            {:noreply, socket}
        end
    end
  end

  def notify_autosave(socket, state, message) do
    push_event(socket, "autosave:status", %{state: state, message: message})
  end

  defp format_changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, fn message -> "#{humanize_field(field)} #{message}" end)
    end)
    |> case do
      [message | _] -> message
      _ -> "Invalid profile values"
    end
  end

  defp humanize_field(field) do
    field
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp maybe_put_profile_flash(socket, true, kind, message), do: put_flash(socket, kind, message)
  defp maybe_put_profile_flash(socket, false, _kind, _message), do: socket

  defp merge_profile_params(existing_profile, params) do
    %{
      "display_name" =>
        Map.get(params, "display_name", Map.get(existing_profile, "display_name", "")),
      "email" => Map.get(params, "email", Map.get(existing_profile, "email", "")),
      "timezone" => Map.get(params, "timezone", Map.get(existing_profile, "timezone", "UTC"))
    }
  end
end

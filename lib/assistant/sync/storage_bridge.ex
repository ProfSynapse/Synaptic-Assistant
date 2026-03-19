defmodule Assistant.Sync.StorageBridge do
  @moduledoc """
  Reconciles provider-neutral Google Workspace storage state with the legacy
  Drive sync tables used by the polling engine.
  """

  alias Assistant.ConnectedDrives
  alias Assistant.Integrations.Google.Auth
  alias Assistant.Integrations.Google.Drive.Changes
  alias Assistant.Repo
  alias Assistant.Storage
  alias Assistant.Sync.StateStore

  @provider "google_drive"

  @spec reconcile_source(binary(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reconcile_source(user_id, source_id, opts \\ []) do
    storage_module = Keyword.get(opts, :storage_module, Storage)
    state_store = Keyword.get(opts, :state_store, StateStore)
    connected_drives = Keyword.get(opts, :connected_drives_module, ConnectedDrives)
    google_auth = Keyword.get(opts, :google_auth_module, Auth)
    drive_changes = Keyword.get(opts, :drive_changes_module, Changes)
    access_token = Keyword.get(opts, :access_token)

    case storage_module.get_connected_source(user_id, @provider, source_id) do
      nil ->
        cleanup_legacy_state(user_id, source_id, state_store, connected_drives)

      source ->
        storage_scopes =
          storage_module.list_scopes(user_id, provider: @provider, source_id: source_id)

        active? = source.enabled or Enum.any?(storage_scopes, &(&1.scope_effect == "include"))
        legacy_drive_id = legacy_drive_id(source_id)

        token =
          if active? and is_nil(state_store.get_cursor(user_id, legacy_drive_id)) do
            resolve_access_token(access_token, google_auth, user_id)
          else
            access_token
          end

        if active? and is_nil(state_store.get_cursor(user_id, legacy_drive_id)) and is_nil(token) do
          {:error, :not_connected}
        else
          Repo.transaction(fn ->
            :ok = upsert_connected_drive(connected_drives, user_id, source, legacy_drive_id)
            :ok = reconcile_legacy_scopes(state_store, user_id, source_id, storage_scopes)

            :ok =
              reconcile_cursor(
                state_store,
                drive_changes,
                user_id,
                source_id,
                legacy_drive_id,
                active?,
                token
              )

            %{active?: active?, scope_count: length(storage_scopes)}
          end)
          |> normalize_transaction_result()
        end
    end
  end

  defp cleanup_legacy_state(user_id, source_id, state_store, connected_drives) do
    legacy_drive_id = legacy_drive_id(source_id)
    legacy_drive_filter = legacy_drive_filter(source_id)

    Repo.transaction(fn ->
      delete_connected_drive(connected_drives, user_id, legacy_drive_id)
      delete_all_legacy_scopes(state_store, user_id, legacy_drive_filter)
      _ = state_store.delete_cursor(user_id, legacy_drive_id)
      %{active?: false, scope_count: 0}
    end)
    |> normalize_transaction_result()
  end

  defp upsert_connected_drive(connected_drives, user_id, source, legacy_drive_id) do
    case connected_drives.connect(user_id, %{
           drive_id: legacy_drive_id,
           drive_name: source.source_name,
           drive_type: source.source_type,
           enabled: source.enabled
         }) do
      {:ok, _drive} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp reconcile_legacy_scopes(state_store, user_id, source_id, storage_scopes) do
    legacy_drive_filter = legacy_drive_filter(source_id)
    existing_scopes = state_store.list_scopes(user_id, drive_id: legacy_drive_filter)

    desired_scopes =
      storage_scopes
      |> Enum.filter(&(&1.scope_type in ["container", "file"]))
      |> Enum.map(&storage_scope_to_legacy_attrs(user_id, source_id, &1))

    desired_keys = MapSet.new(Enum.map(desired_scopes, &legacy_scope_key/1))

    with :ok <- delete_stale_legacy_scopes(state_store, existing_scopes, desired_keys),
         :ok <- upsert_legacy_scopes(state_store, desired_scopes) do
      :ok
    end
  end

  defp delete_stale_legacy_scopes(state_store, existing_scopes, desired_keys) do
    existing_scopes
    |> Enum.reject(&MapSet.member?(desired_keys, legacy_scope_key(&1)))
    |> Enum.reduce_while(:ok, fn scope, :ok ->
      case state_store.delete_scope(scope) do
        {:ok, _deleted} -> {:cont, :ok}
        {:error, reason} -> {:halt, Repo.rollback(reason)}
      end
    end)
  end

  defp upsert_legacy_scopes(state_store, desired_scopes) do
    desired_scopes
    |> Enum.reduce_while(:ok, fn attrs, :ok ->
      case state_store.upsert_scope(attrs) do
        {:ok, _scope} -> {:cont, :ok}
        {:error, reason} -> {:halt, Repo.rollback(reason)}
      end
    end)
  end

  defp reconcile_cursor(
         state_store,
         drive_changes,
         user_id,
         source_id,
         legacy_drive_id,
         active?,
         token
       ) do
    cursor = state_store.get_cursor(user_id, legacy_drive_id)

    cond do
      active? and is_nil(cursor) ->
        api_opts = if is_nil(legacy_drive_id), do: [], else: [drive_id: source_id]

        case drive_changes.get_start_page_token(token, api_opts) do
          {:ok, start_page_token} ->
            case state_store.upsert_cursor(%{
                   user_id: user_id,
                   drive_id: legacy_drive_id,
                   start_page_token: start_page_token,
                   last_poll_at: DateTime.utc_now()
                 }) do
              {:ok, _cursor} -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end

      active? ->
        :ok

      true ->
        _ = state_store.delete_cursor(user_id, legacy_drive_id)
        :ok
    end
  end

  defp delete_all_legacy_scopes(state_store, user_id, legacy_drive_filter) do
    state_store.list_scopes(user_id, drive_id: legacy_drive_filter)
    |> Enum.reduce_while(:ok, fn scope, :ok ->
      case state_store.delete_scope(scope) do
        {:ok, _deleted} -> {:cont, :ok}
        {:error, reason} -> {:halt, Repo.rollback(reason)}
      end
    end)
  end

  defp delete_connected_drive(connected_drives, user_id, legacy_drive_id) do
    case connected_drives.get_connected_source_id(user_id, legacy_drive_id) do
      nil ->
        :ok

      drive_row_id ->
        case connected_drives.disconnect(drive_row_id) do
          {:ok, _drive} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp storage_scope_to_legacy_attrs(user_id, source_id, scope) do
    base = %{
      user_id: user_id,
      drive_id: legacy_drive_id(source_id),
      access_level: scope.access_level || "read_only",
      scope_effect: scope.scope_effect || "include"
    }

    case scope.scope_type do
      "container" ->
        Map.merge(base, %{
          scope_type: "folder",
          folder_id: scope.node_id,
          folder_name: scope.label
        })

      "file" ->
        Map.merge(base, %{
          scope_type: "file",
          folder_name: scope.label,
          file_id: scope.node_id,
          file_name: scope.label,
          file_mime_type: scope.mime_type
        })
    end
  end

  defp legacy_scope_key(%{scope_type: "folder", drive_id: drive_id, folder_id: folder_id}),
    do: {:folder, drive_id, folder_id}

  defp legacy_scope_key(%{scope_type: "file", drive_id: drive_id, file_id: file_id}),
    do: {:file, drive_id, file_id}

  defp legacy_scope_key(%{scope_type: "drive", drive_id: drive_id}),
    do: {:drive, drive_id}

  defp legacy_scope_key(_), do: :unknown

  defp legacy_drive_id("personal"), do: nil
  defp legacy_drive_id(source_id), do: source_id

  defp legacy_drive_filter("personal"), do: :personal
  defp legacy_drive_filter(source_id), do: source_id

  defp resolve_access_token(nil, google_auth, user_id) do
    case google_auth.user_token(user_id) do
      {:ok, token} -> token
      {:error, _} -> nil
    end
  end

  defp resolve_access_token(token, _google_auth, _user_id), do: token

  defp normalize_transaction_result({:ok, result}), do: {:ok, result}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}
  defp normalize_transaction_result(other), do: other
end

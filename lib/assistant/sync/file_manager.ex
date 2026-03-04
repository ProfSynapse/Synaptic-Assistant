# lib/assistant/sync/file_manager.ex — Database operations for sync workspace.
#
# Manages the per-user sync workspace content in the database. All file content is
# encrypted at rest using Cloak AES-GCM at the Ecto layer (Assistant.Encrypted.Binary).
#
# Related files:
#   - lib/assistant/sync/converter.ex (produces content to write)
#   - lib/assistant/sync/workers/sync_poll_worker.ex (consumer)

defmodule Assistant.Sync.FileManager do
  @moduledoc """
  Database-backed operations for the sync workspace.

  Each user's synced files are stored in the database under `synced_files`.
  All file content is encrypted at rest using `Assistant.Encrypted.Binary` 
  (Cloak AES-GCM) at the Ecto layer.
  """

  require Logger
  import Ecto.Query

  alias Assistant.Repo
  alias Assistant.Schemas.SyncedFile

  @doc """
  Write content to a file in the user's sync workspace.

  Updates the `content` field of an existing `SyncedFile`.
  """
  @spec write_file(binary(), String.t(), binary()) ::
          {:ok, String.t()} | {:error, :enoent | :path_not_allowed | term()}
  def write_file(user_id, relative_path, content) do
    with {:ok, path} <- validate_path(relative_path) do
      case Repo.get_by(SyncedFile, user_id: user_id, local_path: path) do
        nil ->
          {:error, :enoent}

        record ->
          record
          |> Ecto.Changeset.change(%{content: content})
          |> Repo.update()
          |> case do
            {:ok, _} -> {:ok, path}
            {:error, changeset} -> {:error, changeset}
          end
      end
    end
  end

  @doc """
  Read a decrypted file from the user's sync workspace.
  """
  @spec read_file(binary(), String.t()) ::
          {:ok, binary()} | {:error, :path_not_allowed | :enoent | term()}
  def read_file(user_id, relative_path) do
    with {:ok, path} <- validate_path(relative_path) do
      case Repo.get_by(SyncedFile, user_id: user_id, local_path: path) do
        nil -> {:error, :enoent}
        %{content: nil} -> {:error, :enoent}
        %{content: content} -> {:ok, content}
      end
    end
  end

  @doc """
  Check if a file exists and has content.
  """
  @spec file_exists?(binary(), String.t()) :: boolean()
  def file_exists?(user_id, relative_path) do
    with {:ok, path} <- validate_path(relative_path) do
      query =
        from s in SyncedFile,
          where: s.user_id == ^user_id and s.local_path == ^path and not is_nil(s.content)

      Repo.exists?(query)
    else
      _ -> false
    end
  end

  @doc """
  Delete a file from the user's sync workspace (clears content).
  """
  @spec delete_file(binary(), String.t()) ::
          :ok | {:error, :path_not_allowed | term()}
  def delete_file(user_id, relative_path) do
    with {:ok, path} <- validate_path(relative_path) do
      case Repo.get_by(SyncedFile, user_id: user_id, local_path: path) do
        nil ->
          :ok

        record ->
          record
          |> Ecto.Changeset.change(%{content: nil})
          |> Repo.update()
          |> case do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  @doc """
  Rename/move a file within the user's sync workspace.
  """
  @spec rename_file(binary(), String.t(), String.t()) ::
          :ok | {:error, :path_not_allowed | term()}
  def rename_file(user_id, old_relative_path, new_relative_path) do
    with {:ok, old_path} <- validate_path(old_relative_path),
         {:ok, new_path} <- validate_path(new_relative_path) do
      case Repo.get_by(SyncedFile, user_id: user_id, local_path: old_path) do
        nil ->
          {:error, :enoent}

        record ->
          record
          |> Ecto.Changeset.change(%{local_path: new_path})
          |> Repo.update()
          |> case do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  @doc """
  List files in the user's sync workspace, optionally filtered by prefix.
  """
  @spec list_files(binary(), String.t()) :: {:ok, [String.t()]}
  def list_files(user_id, relative_path_prefix \\ "") do
    prefix_like = "#{relative_path_prefix}%"

    query =
      from s in SyncedFile,
        where:
          s.user_id == ^user_id and not is_nil(s.content) and like(s.local_path, ^prefix_like),
        select: s.local_path

    {:ok, Repo.all(query)}
  end

  @doc """
  No-op for filesystem directory creation. Kept for compatibility.
  """
  @spec ensure_user_dir(binary()) :: :ok | {:error, term()}
  def ensure_user_dir(_user_id) do
    :ok
  end

  @doc """
  Validate a local path to prevent directory traversal.
  """
  @spec build_path(binary(), String.t()) ::
          {:ok, String.t()} | {:error, :path_not_allowed}
  def build_path(_user_id, relative_path) do
    validate_path(relative_path)
  end

  @doc """
  Compute a checksum of raw content.
  Used by the change detector to compare local vs remote file state.
  """
  @spec checksum(binary()) :: String.t()
  def checksum(content) when is_binary(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  # -- Private --

  defp validate_path(relative_path) do
    if String.contains?(relative_path, "..") or Path.type(relative_path) == :absolute do
      {:error, :path_not_allowed}
    else
      {:ok, relative_path}
    end
  end
end

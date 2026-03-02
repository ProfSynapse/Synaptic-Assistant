# lib/assistant/sync/file_manager.ex — Local filesystem operations for sync workspace.
#
# Manages the per-user sync workspace directory on disk. All file content is
# encrypted at rest using Cloak AES-GCM (via Assistant.Vault). Path validation
# rejects traversal attacks, absolute paths, and symlinks.
#
# Related files:
#   - lib/assistant/vault.ex (Cloak AES-GCM vault)
#   - lib/assistant/sync/converter.ex (produces content to write)
#   - lib/assistant/sync/workers/sync_poll_worker.ex (consumer)
#   - lib/assistant/scheduler/workflow_worker.ex (similar path validation pattern)

defmodule Assistant.Sync.FileManager do
  @moduledoc """
  Local filesystem operations for the sync workspace.

  Each user gets an isolated directory at `{workspace_dir}/{user_id}/`.
  All file content is encrypted at rest using `Assistant.Vault` (Cloak
  AES-GCM). Path validation prevents directory traversal, symlink
  escapes, and absolute path injection.

  ## Security

  Path validation follows the same pattern as `WorkflowWorker.resolve_path/1`:
    1. Reject absolute paths
    2. Reject `..` components
    3. Expand and verify the path resolves within the user's workspace
    4. Reject symlinks via `:file.read_link_info/1`

  ## Encryption

  Content is encrypted with `Assistant.Vault.encrypt!/1` before writing
  and decrypted with `Assistant.Vault.decrypt!/1` after reading. The
  encryption key is configured via `CLOAK_ENCRYPTION_KEY` env var.
  """

  require Logger

  @doc """
  Write encrypted content to a file in the user's sync workspace.

  Creates parent directories as needed. Content is encrypted at rest.

  ## Parameters

    - `user_id` - The user's binary ID
    - `relative_path` - Path relative to the user's workspace directory
    - `content` - Raw content binary to encrypt and write

  ## Returns

    - `{:ok, absolute_path}` on success
    - `{:error, :path_not_allowed}` if path validation fails
    - `{:error, term()}` on I/O failure
  """
  @spec write_file(binary(), String.t(), binary()) ::
          {:ok, String.t()} | {:error, :path_not_allowed | term()}
  def write_file(user_id, relative_path, content) do
    with {:ok, full_path} <- resolve_path(user_id, relative_path) do
      encrypted = Assistant.Vault.encrypt!(content)
      dir = Path.dirname(full_path)

      case File.mkdir_p(dir) do
        :ok ->
          case File.write(full_path, encrypted) do
            :ok ->
              {:ok, full_path}

            {:error, reason} ->
              Logger.error("FileManager: write failed",
                path: full_path,
                reason: inspect(reason)
              )

              {:error, reason}
          end

        {:error, reason} ->
          Logger.error("FileManager: mkdir_p failed",
            dir: dir,
            reason: inspect(reason)
          )

          {:error, reason}
      end
    end
  end

  @doc """
  Read and decrypt a file from the user's sync workspace.

  ## Parameters

    - `user_id` - The user's binary ID
    - `relative_path` - Path relative to the user's workspace directory

  ## Returns

    - `{:ok, content :: binary()}` on success (decrypted)
    - `{:error, :path_not_allowed}` if path validation fails
    - `{:error, :enoent}` if the file does not exist
    - `{:error, term()}` on I/O or decryption failure
  """
  @spec read_file(binary(), String.t()) ::
          {:ok, binary()} | {:error, :path_not_allowed | :enoent | term()}
  def read_file(user_id, relative_path) do
    with {:ok, full_path} <- resolve_path(user_id, relative_path) do
      case File.read(full_path) do
        {:ok, encrypted} ->
          {:ok, Assistant.Vault.decrypt!(encrypted)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Delete a file from the user's sync workspace.

  ## Parameters

    - `user_id` - The user's binary ID
    - `relative_path` - Path relative to the user's workspace directory

  ## Returns

    - `:ok` on success or if the file does not exist
    - `{:error, :path_not_allowed}` if path validation fails
    - `{:error, term()}` on I/O failure
  """
  @spec delete_file(binary(), String.t()) ::
          :ok | {:error, :path_not_allowed | term()}
  def delete_file(user_id, relative_path) do
    with {:ok, full_path} <- resolve_path(user_id, relative_path) do
      case File.rm(full_path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Rename/move a file within the user's sync workspace.

  Both source and destination must resolve within the user's workspace.

  ## Parameters

    - `user_id` - The user's binary ID
    - `old_relative_path` - Current path relative to user's workspace
    - `new_relative_path` - New path relative to user's workspace

  ## Returns

    - `:ok` on success
    - `{:error, :path_not_allowed}` if either path fails validation
    - `{:error, term()}` on I/O failure
  """
  @spec rename_file(binary(), String.t(), String.t()) ::
          :ok | {:error, :path_not_allowed | term()}
  def rename_file(user_id, old_relative_path, new_relative_path) do
    with {:ok, old_path} <- resolve_path(user_id, old_relative_path),
         {:ok, new_path} <- resolve_path(user_id, new_relative_path) do
      new_dir = Path.dirname(new_path)

      with :ok <- File.mkdir_p(new_dir) do
        File.rename(old_path, new_path)
      end
    end
  end

  @doc """
  List all files in the user's sync workspace.

  Returns paths relative to the user's workspace directory.

  ## Returns

    - `{:ok, [String.t()]}` — list of relative paths
  """
  @spec list_files(binary()) :: {:ok, [String.t()]}
  def list_files(user_id) do
    user_dir = user_workspace_dir(user_id)

    if File.dir?(user_dir) do
      files =
        user_dir
        |> list_files_recursive()
        |> Enum.map(fn path -> Path.relative_to(path, user_dir) end)

      {:ok, files}
    else
      {:ok, []}
    end
  end

  @doc """
  Ensure the user's workspace directory exists.

  Called lazily by `write_file/3`, but can be invoked explicitly
  if needed (e.g., on sync scope setup).
  """
  @spec ensure_user_dir(binary()) :: :ok | {:error, term()}
  def ensure_user_dir(user_id) do
    user_dir = user_workspace_dir(user_id)
    File.mkdir_p(user_dir)
  end

  @doc """
  Build and validate a full filesystem path for a user file.

  This is the public entry point for path validation. Returns an error
  if the path is unsafe.

  ## Returns

    - `{:ok, absolute_path}` if the path is safe
    - `{:error, :path_not_allowed}` if validation fails
  """
  @spec build_path(binary(), String.t()) ::
          {:ok, String.t()} | {:error, :path_not_allowed}
  def build_path(user_id, relative_path) do
    resolve_path(user_id, relative_path)
  end

  @doc """
  Compute a checksum of raw content (before encryption).

  Uses SHA-256 truncated to 16 hex characters for compact storage.
  Used by the change detector to compare local vs remote file state.
  """
  @spec checksum(binary()) :: String.t()
  def checksum(content) when is_binary(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  # -- Private --

  defp workspace_dir do
    Application.get_env(:assistant, :sync_workspace_dir, "priv/sync_workspace")
  end

  defp user_workspace_dir(user_id) do
    Path.join(workspace_dir(), user_id)
  end

  # Path validation following WorkflowWorker.resolve_path/1 pattern:
  # 1. Reject absolute paths
  # 2. Reject `..` traversal
  # 3. Expand and verify within user's workspace
  # 4. Reject symlinks
  defp resolve_path(user_id, relative_path) do
    if Path.type(relative_path) == :absolute or String.contains?(relative_path, "..") do
      {:error, :path_not_allowed}
    else
      user_dir = user_workspace_dir(user_id) |> Path.expand()
      resolved = Path.join(user_dir, relative_path) |> Path.expand()

      cond do
        not String.starts_with?(resolved, user_dir) ->
          {:error, :path_not_allowed}

        contains_symlink?(resolved) ->
          {:error, :path_not_allowed}

        true ->
          {:ok, resolved}
      end
    end
  end

  defp contains_symlink?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _ -> false
    end
  end

  defp list_files_recursive(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn entry ->
          full = Path.join(dir, entry)

          case File.stat(full) do
            {:ok, %File.Stat{type: :directory}} -> list_files_recursive(full)
            {:ok, %File.Stat{type: :regular}} -> [full]
            _ -> []
          end
        end)

      {:error, _} ->
        []
    end
  end
end

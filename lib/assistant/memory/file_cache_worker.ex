# lib/assistant/memory/file_cache_worker.ex — Oban worker for async file caching.
#
# Enqueued by ContextFiles.load when a text file is loaded. Calls FileCache
# to summarize the file and persist it as a searchable memory entry.
#
# Related files:
#   - lib/assistant/memory/file_cache.ex (core logic)
#   - lib/assistant/orchestrator/context_files.ex (enqueue site)

defmodule Assistant.Memory.FileCacheWorker do
  use Oban.Worker,
    queue: :memory,
    max_attempts: 2,
    unique: [period: 300, keys: [:user_id, :file_path]]

  alias Assistant.Memory.FileCache

  @impl true
  def perform(%Oban.Job{args: %{"user_id" => user_id, "file_path" => path, "content" => content}}) do
    case FileCache.cache_file(user_id, path, content) do
      {:ok, _} -> :ok
      {:error, :no_compaction_model} -> {:cancel, :no_compaction_model}
      {:error, reason} -> {:error, reason}
    end
  end
end

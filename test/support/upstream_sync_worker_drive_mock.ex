# test/support/upstream_sync_worker_drive_mock.ex — Test double for Google Drive
# operations used by the upstream sync worker tests.

defmodule Assistant.Sync.Workers.UpstreamSyncWorkerDriveMock do
  @moduledoc false

  @modified_time "2026-03-19T09:30:00Z"

  def update_file_content(access_token, file_id, content, mime_type, opts \\ []) do
    record_call({:update_file_content, access_token, file_id, content, mime_type, opts})

    case Process.get(:upstream_drive_update_result, :ok) do
      :ok ->
        {:ok,
         %{
           id: file_id,
           name: "example.md",
           web_view_link: "https://example.com/#{file_id}",
           modified_time: @modified_time,
           md5_checksum: "mock-md5",
           version: "7",
           mime_type: mime_type
         }}

      {:ok, response} when is_map(response) ->
        {:ok, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def trash_file(access_token, file_id, opts \\ []) do
    record_call({:trash_file, access_token, file_id, opts})

    case Process.get(:upstream_drive_trash_result, :ok) do
      :ok ->
        {:ok,
         %{
           id: file_id,
           name: "example.md",
           trashed: true,
           modified_time: @modified_time,
           md5_checksum: "mock-md5",
           version: "7"
         }}

      {:ok, response} when is_map(response) ->
        {:ok, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def calls do
    Enum.reverse(Process.get(:upstream_drive_calls, []))
  end

  def classify_write_error(:conflict), do: :conflict
  def classify_write_error(:timeout), do: :transient
  def classify_write_error(_reason), do: :fatal

  def reset do
    Process.delete(:upstream_drive_calls)
    Process.delete(:upstream_drive_update_result)
    Process.delete(:upstream_drive_trash_result)
    :ok
  end

  defp record_call(call) do
    calls = Process.get(:upstream_drive_calls, [])
    Process.put(:upstream_drive_calls, [call | calls])
  end
end

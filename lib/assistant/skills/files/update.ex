# lib/assistant/skills/files/update.ex — Handler for files.update skill.
#
# Reads a Google Drive file, applies a string replacement (search -> replace),
# and writes the modified content back. Supports single or global replacement.
#
# Related files:
#   - lib/assistant/integrations/google/drive.ex (Drive API client)
#   - lib/assistant/skills/handler.ex (behaviour)
#   - priv/skills/files/update.md (skill definition)

defmodule Assistant.Skills.Files.Update do
  @moduledoc """
  Skill handler for updating Google Drive file content via string replacement.

  Reads file content, applies `String.replace/4` with the given search and
  replace strings, then writes the result back using a multipart upload.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Skills.Result
  alias Assistant.Sync.WriteCoordinator

  @impl true
  def execute(flags, context) do
    case Map.get(context.integrations, :drive) do
      nil ->
        {:ok, %Result{status: :error, content: "Drive integration not configured."}}

      drive ->
        case context.metadata[:google_token] do
          nil ->
            {:ok,
             %Result{
               status: :error,
               content: "Google authentication required. Please connect your Google account."
             }}

          token ->
            do_execute(flags, drive, token, context)
        end
    end
  end

  defp do_execute(flags, drive, token, context) do
    file_id = Map.get(flags, "id")
    search = Map.get(flags, "search")
    replace = Map.get(flags, "replace")
    replace_all? = Map.get(flags, "all", false)

    cond do
      is_nil(file_id) || file_id == "" ->
        {:ok, %Result{status: :error, content: "Missing required parameter: --id (file ID)."}}

      is_nil(search) || search == "" ->
        {:ok,
         %Result{status: :error, content: "Missing required parameter: --search (text to find)."}}

      is_nil(replace) ->
        {:ok,
         %Result{
           status: :error,
           content: "Missing required parameter: --replace (replacement text)."
         }}

      true ->
        do_update(drive, token, file_id, search, replace, replace_all?, context)
    end
  end

  defp do_update(drive, token, file_id, search, replace, replace_all?, context) do
      with {:ok, {content, precondition_opts}} <- read_with_preconditions(drive, token, file_id),
         {:changed, updated} <- apply_replacement(content, search, replace, replace_all?),
         {:ok, file} <-
           update_with_preconditions(
             drive,
             token,
             file_id,
             updated,
             precondition_opts,
             context
           ) do
      count = count_replacements(content, search, replace_all?)

      {:ok,
       %Result{
         status: :ok,
         content: "Updated #{file.name}: replaced #{count} occurrence(s) of '#{search}'.",
         side_effects: [:file_updated],
         metadata: %{file_id: file.id, file_name: file.name, replacements: count}
       }}
    else
      :unchanged ->
        {:ok, %Result{status: :ok, content: "No changes made (pattern not found)."}}

      {:error, :not_found} ->
        {:ok,
         %Result{
           status: :error,
           content:
             "File not found: #{file_id}. Check the file ID and ensure the service account has access."
         }}

      {:error, :conflict} ->
        {:ok,
         %Result{
           status: :error,
           content:
             "This file changed while I was editing. I paused to avoid overwriting someone. Please retry against the latest version."
         }}

      {:error, reason} ->
        {:ok,
         %Result{
           status: :error,
           content: "Failed to update file #{file_id}: #{inspect(reason)}"
         }}
    end
  end

  defp apply_replacement(content, search, replace, replace_all?) do
    global = replace_all? == true || replace_all? == "true"
    opts = if global, do: [:global], else: []
    updated = String.replace(content, search, replace, opts)

    if updated == content, do: :unchanged, else: {:changed, updated}
  end

  defp count_replacements(content, search, replace_all?) do
    global = replace_all? == true || replace_all? == "true"
    total = length(String.split(content, search)) - 1

    if global, do: total, else: min(total, 1)
  end

  defp read_with_preconditions(drive, token, file_id) do
    with {:ok, content} <- drive.read_file(token, file_id) do
      if conflict_protection_enabled?() and function_exported?(drive, :get_file, 2) do
        case drive.get_file(token, file_id) do
          {:ok, file_meta} ->
            {:ok, {content, precondition_opts(file_meta)}}

          {:error, _reason} ->
            {:ok, {content, []}}
        end
      else
        {:ok, {content, []}}
      end
    end
  end

  defp update_with_preconditions(
         drive,
         token,
         file_id,
         updated_content,
         precondition_opts,
         context
       ) do
    cond do
      precondition_opts != [] and function_exported?(drive, :update_file_content, 5) ->
        user_id = context.metadata[:user_id] || "unknown"

        WriteCoordinator.execute(
          fn -> drive.update_file_content(token, file_id, updated_content, "text/plain", precondition_opts) end,
          user_id: user_id,
          file_id: file_id,
          intent_id: "files.update:#{file_id}",
          classify_error: &classify_drive_error(drive, &1),
          event_hook: maybe_event_hook(context, file_id, "files.update")
        )

      true ->
        drive.update_file_content(token, file_id, updated_content)
    end
  end

  defp precondition_opts(file_meta) do
    []
    |> maybe_put_expected(:expected_modified_time, Map.get(file_meta, :modified_time))
    |> maybe_put_expected(:expected_checksum, Map.get(file_meta, :md5_checksum))
    |> maybe_put_expected(:expected_version, Map.get(file_meta, :version))
  end

  defp maybe_put_expected(opts, _key, nil), do: opts
  defp maybe_put_expected(opts, _key, ""), do: opts
  defp maybe_put_expected(opts, key, value), do: Keyword.put(opts, key, value)

  defp conflict_protection_enabled? do
    Application.get_env(:assistant, :google_write_conflict_protection, false)
  end

  defp audit_history_enabled? do
    Application.get_env(:assistant, :google_write_audit_history, false)
  end

  defp maybe_event_hook(context, file_id, action) do
    user_id = context.metadata[:user_id]

    if audit_history_enabled?() and is_binary(user_id) do
      fn event ->
        Assistant.Sync.StateStore.record_write_coordinator_event(user_id, file_id, action, event)
      end
    else
      nil
    end
  end

  defp classify_drive_error(drive, reason) do
    if function_exported?(drive, :classify_write_error, 1) do
      drive.classify_write_error(reason)
    else
      if reason == :conflict, do: :conflict, else: :fatal
    end
  end
end

# lib/assistant/skills/files/update.ex — Handler for files.update skill.
#
# Reads a Google Drive file, applies a string replacement (search → replace),
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
  alias Assistant.Integrations.Google.Drive

  @impl true
  def execute(flags, context) do
    drive = Map.get(context.integrations, :drive, Drive)
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
        do_update(drive, file_id, search, replace, replace_all?)
    end
  end

  defp do_update(drive, file_id, search, replace, replace_all?) do
    with {:ok, content} <- drive.read_file(file_id),
         {:changed, updated} <- apply_replacement(content, search, replace, replace_all?),
         {:ok, file} <- drive.update_file_content(file_id, updated) do
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
end

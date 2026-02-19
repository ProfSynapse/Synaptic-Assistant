# lib/assistant/skills/files/write.ex — Handler for files.write skill.
#
# Creates a new file in Google Drive with the given name and content.
# Supports optional folder placement and MIME type specification.
#
# Related files:
#   - lib/assistant/integrations/google/drive.ex (Drive API client)
#   - lib/assistant/skills/handler.ex (behaviour)
#   - priv/skills/files/write.md (skill definition)

defmodule Assistant.Skills.Files.Write do
  @moduledoc """
  Skill handler for creating files in Google Drive.

  Creates a new file with the provided name and content. Returns
  confirmation with the file ID and web view link.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Skills.Result

  @impl true
  def execute(flags, context) do
    case Map.get(context.integrations, :drive) do
      nil ->
        {:ok, %Result{status: :error, content: "Google Drive integration not configured."}}

      drive ->
        token = context.google_token
        name = Map.get(flags, "name")
        content = Map.get(flags, "content", "")
        folder = Map.get(flags, "folder")
        mime_type = Map.get(flags, "type")

        cond do
          is_nil(name) || name == "" ->
            {:ok, %Result{status: :error, content: "Missing required parameter: --name (file name)."}}

          is_nil(content) ->
            {:ok, %Result{status: :error, content: "Missing required parameter: --content (file content)."}}

          true ->
            create_file(drive, token, name, content, folder, mime_type)
        end
    end
  end

  defp create_file(drive, token, name, content, folder, mime_type) do
    opts =
      []
      |> maybe_add(:parent_id, folder)
      |> maybe_add(:mime_type, mime_type)

    case drive.create_file(token, name, content, opts) do
      {:ok, file} ->
        link_line = if file[:web_view_link], do: "\nLink: #{file.web_view_link}", else: ""

        {:ok,
         %Result{
           status: :ok,
           content: "File created successfully.\nName: #{file.name}\nID: #{file.id}#{link_line}",
           side_effects: [:file_created],
           metadata: %{file_id: file.id, file_name: file.name}
         }}

      {:error, reason} ->
        {:ok,
         %Result{
           status: :error,
           content: "Failed to create file '#{name}': #{inspect(reason)}"
         }}
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, _key, ""), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
end

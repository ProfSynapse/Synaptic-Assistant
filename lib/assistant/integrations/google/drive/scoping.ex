# lib/assistant/integrations/google/drive/scoping.ex — Drive query scoping.
#
# Builds Google Drive API query parameters from a list of enabled drives.
# Used by skill handlers (files.search, files.archive) to constrain which
# drives are searched. The Drive client itself is scope-agnostic — scoping
# is a business concern at the skill layer (ADR-3).
#
# Related files:
#   - lib/assistant/integrations/google/drive.ex (Drive API client)
#   - lib/assistant/skills/files/search.ex (consumer — merges scoping params)
#   - lib/assistant/skills/files/archive.ex (consumer — merges scoping params)
#   - lib/assistant/connected_drives.ex (provides enabled_for_user/1)

defmodule Assistant.Integrations.Google.Drive.Scoping do
  @moduledoc false

  @type drive_entry :: %{drive_id: String.t() | nil, drive_type: String.t()}

  @doc """
  Build Google Drive API query parameters from a list of enabled drives.

  Returns a keyword list to merge into `files.list` API options.

  ## Scoping rules

  - Empty list → `{:error, :no_drives_enabled}`
  - Only personal drive → `[corpora: "user", supportsAllDrives: true]`
  - Single shared drive → `[corpora: "drive", driveId: id, ...]`
  - Multiple drives (any mix) → `[corpora: "allDrives", ...]`
  """
  @spec build_query_params([drive_entry()]) ::
          {:ok, keyword()} | {:error, :no_drives_enabled}
  def build_query_params([]), do: {:error, :no_drives_enabled}

  def build_query_params(enabled_drives) do
    personal? = Enum.any?(enabled_drives, &(&1.drive_type == "personal"))
    shared = Enum.filter(enabled_drives, &(&1.drive_type == "shared"))

    params =
      case {personal?, shared} do
        {true, []} ->
          [corpora: "user", supportsAllDrives: true]

        {false, [single]} ->
          [
            corpora: "drive",
            driveId: single.drive_id,
            includeItemsFromAllDrives: true,
            supportsAllDrives: true
          ]

        _ ->
          [
            corpora: "allDrives",
            includeItemsFromAllDrives: true,
            supportsAllDrives: true
          ]
      end

    {:ok, params}
  end
end

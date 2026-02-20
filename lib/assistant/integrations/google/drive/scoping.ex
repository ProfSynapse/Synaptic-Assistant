# lib/assistant/integrations/google/drive/scoping.ex — Drive query scoping.
#
# Builds Google Drive API query parameters from a list of enabled drives.
# Used by skill handlers (files.search, files.archive) to constrain which
# drives are searched. The Drive client itself is scope-agnostic — scoping
# is a business concern at the skill layer (ADR-3).
#
# Returns a list of keyword-list "scopes" so callers issue one API call per
# scope and merge results. This avoids `corpora: "allDrives"` which returns
# files from shared drives the user has not explicitly enabled.
#
# Related files:
#   - lib/assistant/integrations/google/drive.ex (Drive API client)
#   - lib/assistant/skills/files/search.ex (consumer — iterates scopes)
#   - lib/assistant/skills/files/archive.ex (consumer — iterates scopes)
#   - lib/assistant/connected_drives.ex (provides enabled_for_user/1)

defmodule Assistant.Integrations.Google.Drive.Scoping do
  @moduledoc false

  @type drive_entry :: %{drive_id: String.t() | nil, drive_type: String.t()}

  @doc """
  Build Google Drive API query parameters from a list of enabled drives.

  Returns a list of keyword lists — one per scope to query. Callers should
  issue one `files.list` API call per scope and merge (deduplicate) results.

  ## Scoping rules

  - Empty list → `{:error, :no_drives_enabled}`
  - Only personal drive → single scope `[corpora: "user"]`
  - One shared drive → single scope `[corpora: "drive", driveId: id, ...]`
  - Multiple shared drives → one scope per drive
  - Personal + shared → personal scope + one scope per shared drive
  """
  @spec build_query_params([drive_entry()]) ::
          {:ok, [keyword()]} | {:error, :no_drives_enabled}
  def build_query_params([]), do: {:error, :no_drives_enabled}

  def build_query_params(enabled_drives) do
    personal? = Enum.any?(enabled_drives, &(&1.drive_type == "personal"))
    shared = Enum.filter(enabled_drives, &(&1.drive_type == "shared"))

    scopes =
      personal_scope(personal?) ++ shared_scopes(shared)

    {:ok, scopes}
  end

  defp personal_scope(true), do: [[corpora: "user", supportsAllDrives: true]]
  defp personal_scope(false), do: []

  defp shared_scopes(shared_drives) do
    Enum.map(shared_drives, fn drive ->
      [
        corpora: "drive",
        driveId: drive.drive_id,
        includeItemsFromAllDrives: true,
        supportsAllDrives: true
      ]
    end)
  end
end

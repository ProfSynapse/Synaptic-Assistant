# test/assistant/skills/files/search_test.exs
#
# Tests for the files.search skill handler. The search skill queries the
# SyncedFile table directly via Ecto, so these tests require database access.
# Tests result formatting, type filtering, and error handling.

defmodule Assistant.Skills.Files.SearchTest do
  use Assistant.DataCase, async: true

  alias Assistant.Skills.Files.Search
  alias Assistant.Skills.Result

  # ---------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------

  defp build_context(overrides \\ %{}) do
    base = %{
      user_id: "user-search-1",
      integrations: %{},
      metadata: %{}
    }

    Map.merge(base, overrides)
  end

  defp insert_synced_file!(attrs) do
    defaults = %{
      user_id: "user-search-1",
      drive_file_id: Ecto.UUID.generate(),
      drive_file_name: "Test File.md",
      drive_mime_type: "application/vnd.google-apps.document",
      local_path: "docs/test-file.md",
      local_format: "md",
      sync_status: "synced",
      content: "test content",
      last_synced_at: DateTime.utc_now()
    }

    merged = Map.merge(defaults, attrs)

    %Assistant.Schemas.SyncedFile{}
    |> Assistant.Schemas.SyncedFile.changeset(merged)
    |> Repo.insert!()
  end

  # ---------------------------------------------------------------
  # Basic search
  # ---------------------------------------------------------------

  describe "execute/2 basic search" do
    test "returns 'No files found' when results are empty" do
      {:ok, result} = Search.execute(%{}, build_context())

      assert result.status == :ok
      assert result.content =~ "No files found"
      assert result.metadata.count == 0
    end

    test "returns matching files by name" do
      insert_synced_file!(%{drive_file_name: "Q1 Report.md", local_path: "reports/q1-report.md"})

      {:ok, result} = Search.execute(%{"query" => "Q1"}, build_context())

      assert result.status == :ok
      assert result.content =~ "Q1 Report.md"
      assert result.metadata.count == 1
    end

    test "returns matching files by local path" do
      insert_synced_file!(%{drive_file_name: "Notes.md", local_path: "meetings/standup.md"})

      {:ok, result} = Search.execute(%{"query" => "standup"}, build_context())

      assert result.status == :ok
      assert result.content =~ "Notes.md"
    end

    test "does not return files from other users" do
      insert_synced_file!(%{
        user_id: "other-user",
        drive_file_name: "Secret.md",
        local_path: "secret.md"
      })

      {:ok, result} = Search.execute(%{"query" => "Secret"}, build_context())

      assert result.content =~ "No files found"
    end
  end

  # ---------------------------------------------------------------
  # Type filtering
  # ---------------------------------------------------------------

  describe "execute/2 type filtering" do
    test "filters by document type" do
      insert_synced_file!(%{
        drive_file_name: "Doc.md",
        local_path: "doc.md",
        drive_mime_type: "application/vnd.google-apps.document"
      })

      insert_synced_file!(%{
        drive_file_name: "Sheet.csv",
        local_path: "sheet.csv",
        drive_mime_type: "application/vnd.google-apps.spreadsheet"
      })

      {:ok, result} = Search.execute(%{"type" => "doc"}, build_context())

      assert result.content =~ "Doc.md"
      refute result.content =~ "Sheet.csv"
    end

    test "returns error for unknown type" do
      {:ok, result} = Search.execute(%{"type" => "banana"}, build_context())

      assert result.status == :error
      assert result.content =~ "Unknown file type"
      assert result.content =~ "banana"
    end
  end

  # ---------------------------------------------------------------
  # Folder filtering
  # ---------------------------------------------------------------

  describe "execute/2 folder filtering" do
    test "filters by folder path prefix" do
      insert_synced_file!(%{
        drive_file_name: "InFolder.md",
        local_path: "projects/atlas/notes.md"
      })

      insert_synced_file!(%{
        drive_file_name: "Outside.md",
        local_path: "other/doc.md"
      })

      {:ok, result} = Search.execute(%{"folder" => "atlas"}, build_context())

      assert result.content =~ "InFolder.md"
      refute result.content =~ "Outside.md"
    end
  end

  # ---------------------------------------------------------------
  # Friendly type display
  # ---------------------------------------------------------------

  describe "execute/2 result formatting" do
    test "displays friendly type names" do
      types = [
        {"application/vnd.google-apps.document", "Google Doc"},
        {"application/vnd.google-apps.spreadsheet", "Google Sheet"},
        {"application/vnd.google-apps.folder", "Folder"},
        {"application/pdf", "PDF"}
      ]

      for {mime, label} <- types do
        insert_synced_file!(%{
          drive_mime_type: mime,
          drive_file_name: "file-#{label}.md",
          local_path: "file-#{label}.md"
        })

        {:ok, result} = Search.execute(%{"query" => "file-#{label}"}, build_context())
        assert result.content =~ label, "Expected '#{label}' for mime '#{mime}'"
      end
    end
  end

  # ---------------------------------------------------------------
  # Error handling
  # ---------------------------------------------------------------

  describe "execute/2 error handling" do
    test "returns error when user_id is nil" do
      context = build_context(%{user_id: nil})

      {:ok, result} = Search.execute(%{}, context)

      assert result.status == :error
      assert result.content =~ "User context is required"
    end
  end
end

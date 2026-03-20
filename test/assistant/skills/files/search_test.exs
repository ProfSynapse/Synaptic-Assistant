# test/assistant/skills/files/search_test.exs
#
# Tests for the files.search skill handler. The search skill queries the
# SyncedFile table directly via Ecto, so these tests require database access.
# Tests result formatting, type filtering, and error handling.

defmodule Assistant.Skills.Files.SearchTest do
  use Assistant.DataCase, async: true
  @moduletag :external

  alias Assistant.Schemas.User
  alias Assistant.Skills.Files.Search
  # ---------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------

  setup do
    user = insert_user("user-search")
    other_user = insert_user("other-user")
    %{user: user, other_user: other_user}
  end

  defp build_context(user_id, overrides \\ %{}) do
    base = %{
      user_id: user_id,
      integrations: %{},
      metadata: %{}
    }

    Map.merge(base, overrides)
  end

  defp insert_synced_file!(user_id, attrs) do
    defaults = %{
      user_id: user_id,
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
    test "returns 'No files found' when results are empty", %{user: user} do
      {:ok, result} = Search.execute(%{}, build_context(user.id))

      assert result.status == :ok
      assert result.content =~ "No files found"
      assert result.metadata.count == 0
    end

    test "returns matching files by name", %{user: user} do
      insert_synced_file!(user.id, %{
        drive_file_name: "Q1 Report.md",
        local_path: "reports/q1-report.md"
      })

      {:ok, result} = Search.execute(%{"query" => "Q1"}, build_context(user.id))

      assert result.status == :ok
      assert result.content =~ "Q1 Report.md"
      assert result.metadata.count == 1
    end

    test "returns matching files by local path", %{user: user} do
      insert_synced_file!(user.id, %{
        drive_file_name: "Notes.md",
        local_path: "meetings/standup.md"
      })

      {:ok, result} = Search.execute(%{"query" => "standup"}, build_context(user.id))

      assert result.status == :ok
      assert result.content =~ "Notes.md"
    end

    test "does not return files from other users", %{user: user, other_user: other_user} do
      insert_synced_file!(other_user.id, %{
        drive_file_name: "Secret.md",
        local_path: "secret.md"
      })

      {:ok, result} = Search.execute(%{"query" => "Secret"}, build_context(user.id))

      assert result.content =~ "No files found"
    end
  end

  # ---------------------------------------------------------------
  # Type filtering
  # ---------------------------------------------------------------

  describe "execute/2 type filtering" do
    test "filters by document type", %{user: user} do
      insert_synced_file!(user.id, %{
        drive_file_name: "Doc.md",
        local_path: "doc.md",
        drive_mime_type: "application/vnd.google-apps.document"
      })

      insert_synced_file!(user.id, %{
        drive_file_name: "Sheet.csv",
        local_path: "sheet.csv",
        drive_mime_type: "application/vnd.google-apps.spreadsheet"
      })

      {:ok, result} = Search.execute(%{"type" => "doc"}, build_context(user.id))

      assert result.content =~ "Doc.md"
      refute result.content =~ "Sheet.csv"
    end

    test "returns error for unknown type", %{user: user} do
      {:ok, result} = Search.execute(%{"type" => "banana"}, build_context(user.id))

      assert result.status == :error
      assert result.content =~ "Unknown file type"
      assert result.content =~ "banana"
    end
  end

  # ---------------------------------------------------------------
  # Folder filtering
  # ---------------------------------------------------------------

  describe "execute/2 folder filtering" do
    test "filters by folder path prefix", %{user: user} do
      insert_synced_file!(user.id, %{
        drive_file_name: "InFolder.md",
        local_path: "projects/atlas/notes.md"
      })

      insert_synced_file!(user.id, %{
        drive_file_name: "Outside.md",
        local_path: "other/doc.md"
      })

      {:ok, result} = Search.execute(%{"folder" => "atlas"}, build_context(user.id))

      assert result.content =~ "InFolder.md"
      refute result.content =~ "Outside.md"
    end
  end

  # ---------------------------------------------------------------
  # Friendly type display
  # ---------------------------------------------------------------

  describe "execute/2 result formatting" do
    test "displays friendly type names", %{user: user} do
      types = [
        {"application/vnd.google-apps.document", "Google Doc"},
        {"application/vnd.google-apps.spreadsheet", "Google Sheet"},
        {"application/vnd.google-apps.folder", "Folder"},
        {"application/pdf", "PDF"}
      ]

      for {mime, label} <- types do
        insert_synced_file!(user.id, %{
          drive_mime_type: mime,
          drive_file_name: "file-#{label}.md",
          local_path: "file-#{label}.md"
        })

        {:ok, result} = Search.execute(%{"query" => "file-#{label}"}, build_context(user.id))
        assert result.content =~ label, "Expected '#{label}' for mime '#{mime}'"
      end
    end
  end

  # ---------------------------------------------------------------
  # Error handling
  # ---------------------------------------------------------------

  describe "execute/2 error handling" do
    test "returns error when user_id is nil" do
      context = build_context(nil)

      {:ok, result} = Search.execute(%{}, context)

      assert result.status == :error
      assert result.content =~ "User context is required"
    end
  end

  defp insert_user(prefix) do
    %User{}
    |> User.changeset(%{
      external_id: "#{prefix}-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Repo.insert!()
  end
end

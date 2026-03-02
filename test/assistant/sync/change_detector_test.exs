# test/assistant/sync/change_detector_test.exs
#
# Tests for Assistant.Sync.ChangeDetector — pure conflict detection functions.
# No database access required; all inputs are passed as arguments.
#
# Related files:
#   - lib/assistant/sync/change_detector.ex (module under test)
#   - lib/assistant/schemas/synced_file.ex (SyncedFile struct used as input)

defmodule Assistant.Sync.ChangeDetectorTest do
  use ExUnit.Case, async: true

  alias Assistant.Sync.ChangeDetector
  alias Assistant.Schemas.SyncedFile

  # ---------------------------------------------------------------
  # detect_conflict/2
  # ---------------------------------------------------------------

  describe "detect_conflict/2" do
    test "returns :remote_updated when synced_file is nil (new file)" do
      change = %{modified_time: "2026-03-02T12:00:00Z", removed: false}
      assert :remote_updated = ChangeDetector.detect_conflict(nil, change)
    end

    test "returns :remote_updated when remote is newer and local unchanged" do
      synced_file = %SyncedFile{
        remote_modified_at: ~U[2026-03-01 10:00:00Z],
        local_checksum: "abc123",
        remote_checksum: "abc123"
      }

      change = %{modified_time: "2026-03-02T12:00:00Z", removed: false}
      assert :remote_updated = ChangeDetector.detect_conflict(synced_file, change)
    end

    test "returns :no_conflict when remote has not changed" do
      now = DateTime.utc_now()

      synced_file = %SyncedFile{
        remote_modified_at: now,
        local_checksum: "same",
        remote_checksum: "same"
      }

      # Remote time is same or older
      past = DateTime.add(now, -3600, :second)
      change = %{modified_time: DateTime.to_iso8601(past), removed: false}
      assert :no_conflict = ChangeDetector.detect_conflict(synced_file, change)
    end

    test "returns :conflict when both local and remote changed" do
      synced_file = %SyncedFile{
        remote_modified_at: ~U[2026-03-01 10:00:00Z],
        local_checksum: "local-changed",
        remote_checksum: "original"
      }

      change = %{modified_time: "2026-03-02T12:00:00Z", removed: false}
      assert :conflict = ChangeDetector.detect_conflict(synced_file, change)
    end

    test "returns :remote_updated when file was removed" do
      synced_file = %SyncedFile{
        remote_modified_at: ~U[2026-03-01 10:00:00Z],
        local_checksum: "abc",
        remote_checksum: "abc"
      }

      change = %{modified_time: nil, removed: true}
      assert :remote_updated = ChangeDetector.detect_conflict(synced_file, change)
    end

    test "returns :remote_updated when modified_time is nil" do
      synced_file = %SyncedFile{
        remote_modified_at: ~U[2026-03-01 10:00:00Z],
        local_checksum: "abc",
        remote_checksum: "abc"
      }

      change = %{modified_time: nil, removed: false}
      assert :remote_updated = ChangeDetector.detect_conflict(synced_file, change)
    end

    test "handles DateTime objects (not just strings) for modified_time" do
      synced_file = %SyncedFile{
        remote_modified_at: ~U[2026-03-01 10:00:00Z],
        local_checksum: "same",
        remote_checksum: "same"
      }

      change = %{modified_time: ~U[2026-03-02 12:00:00Z], removed: false}
      assert :remote_updated = ChangeDetector.detect_conflict(synced_file, change)
    end

    test "local not modified when local_checksum is nil" do
      synced_file = %SyncedFile{
        remote_modified_at: ~U[2026-03-01 10:00:00Z],
        local_checksum: nil,
        remote_checksum: "abc"
      }

      change = %{modified_time: "2026-03-02T12:00:00Z", removed: false}
      # Even though remote changed, nil local_checksum means no local modification
      assert :remote_updated = ChangeDetector.detect_conflict(synced_file, change)
    end

    test "local not modified when remote_checksum is nil" do
      synced_file = %SyncedFile{
        remote_modified_at: ~U[2026-03-01 10:00:00Z],
        local_checksum: "abc",
        remote_checksum: nil
      }

      change = %{modified_time: "2026-03-02T12:00:00Z", removed: false}
      assert :remote_updated = ChangeDetector.detect_conflict(synced_file, change)
    end
  end

  # ---------------------------------------------------------------
  # generate_conflict_path/1
  # ---------------------------------------------------------------

  describe "generate_conflict_path/1" do
    test "appends .conflict.{timestamp} before extension" do
      path = ChangeDetector.generate_conflict_path("notes.md")
      assert path =~ ~r/^notes\.conflict\.\d{8}T\d{6}Z\.md$/
    end

    test "handles files without extension" do
      path = ChangeDetector.generate_conflict_path("README")
      assert path =~ ~r/^README\.conflict\.\d{8}T\d{6}Z$/
    end

    test "handles nested paths" do
      path = ChangeDetector.generate_conflict_path("docs/report.csv")
      assert path =~ ~r/^docs\/report\.conflict\.\d{8}T\d{6}Z\.csv$/
    end
  end

  # ---------------------------------------------------------------
  # generate_archive_path/1
  # ---------------------------------------------------------------

  describe "generate_archive_path/1" do
    test "appends .archived.{timestamp} before extension" do
      path = ChangeDetector.generate_archive_path("notes.md")
      assert path =~ ~r/^notes\.archived\.\d{8}T\d{6}Z\.md$/
    end

    test "handles files without extension" do
      path = ChangeDetector.generate_archive_path("Makefile")
      assert path =~ ~r/^Makefile\.archived\.\d{8}T\d{6}Z$/
    end
  end

  # ---------------------------------------------------------------
  # trash_action/1
  # ---------------------------------------------------------------

  describe "trash_action/1" do
    test "returns :ignore for nil (no local record)" do
      assert :ignore = ChangeDetector.trash_action(nil)
    end

    test "returns :archive for existing synced file" do
      synced_file = %SyncedFile{
        id: Ecto.UUID.generate(),
        local_path: "test.md"
      }

      assert :archive = ChangeDetector.trash_action(synced_file)
    end
  end
end

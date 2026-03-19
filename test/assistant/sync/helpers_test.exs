# test/assistant/sync/helpers_test.exs
#
# Tests for Assistant.Sync.Helpers — shared utility functions for the sync engine.
#
# Related files:
#   - lib/assistant/sync/helpers.ex (module under test)
#   - lib/assistant/sync/workers/sync_poll_worker.ex (consumer)
#   - lib/assistant/sync/change_detector.ex (consumer)

defmodule Assistant.Sync.HelpersTest do
  use ExUnit.Case, async: true

  alias Assistant.Sync.Helpers

  describe "parse_time/1" do
    test "returns nil for nil input" do
      assert Helpers.parse_time(nil) == nil
    end

    test "returns DateTime unchanged" do
      dt = ~U[2026-03-02 12:00:00Z]
      assert Helpers.parse_time(dt) == ~U[2026-03-02 12:00:00.000000Z]
    end

    test "parses ISO 8601 string" do
      assert %DateTime{year: 2026, month: 3, day: 2} =
               Helpers.parse_time("2026-03-02T12:00:00Z")
    end

    test "parses ISO 8601 with offset" do
      assert %DateTime{} = Helpers.parse_time("2026-03-02T12:00:00+05:00")
    end

    test "returns nil for invalid date string" do
      assert Helpers.parse_time("not-a-date") == nil
    end

    test "returns nil for empty string" do
      assert Helpers.parse_time("") == nil
    end

    test "returns nil for non-string, non-DateTime, non-nil input" do
      assert Helpers.parse_time(12345) == nil
      assert Helpers.parse_time(:atom) == nil
      assert Helpers.parse_time(%{}) == nil
    end
  end
end

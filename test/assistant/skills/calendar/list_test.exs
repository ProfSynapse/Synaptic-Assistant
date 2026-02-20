# test/assistant/skills/calendar/list_test.exs
#
# Tests for the calendar.list skill handler. Uses a MockCalendar module
# injected via context.integrations[:calendar] to avoid real API calls.
# Tests date range building, limit parsing, and output formatting.

defmodule Assistant.Skills.Calendar.ListTest do
  use ExUnit.Case, async: true

  alias Assistant.Skills.Calendar.List
  alias Assistant.Skills.Context

  # ---------------------------------------------------------------
  # Mock Calendar module
  # ---------------------------------------------------------------

  defmodule MockCalendar do
    @moduledoc false

    def list_events(_token, calendar_id, opts) do
      send(self(), {:cal_list, calendar_id, opts})

      case Process.get(:mock_cal_list_response) do
        nil -> {:ok, []}
        response -> response
      end
    end
  end

  # ---------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------

  defp build_context(overrides \\ %{}) do
    base = %Context{
      conversation_id: "conv-1",
      execution_id: "exec-1",
      user_id: "user-1",
      integrations: %{calendar: MockCalendar},
      metadata: %{google_token: "test-access-token"}
    }

    Map.merge(base, overrides)
  end

  defp set_mock_response(response) do
    Process.put(:mock_cal_list_response, response)
  end

  defp mock_event(attrs \\ %{}) do
    Map.merge(
      %{
        id: "evt_abc",
        summary: "Team Meeting",
        start: "2026-02-19T09:00:00Z",
        end: "2026-02-19T10:00:00Z",
        location: nil,
        attendees: []
      },
      attrs
    )
  end

  # ---------------------------------------------------------------
  # Basic listing
  # ---------------------------------------------------------------

  describe "execute/2 basic listing" do
    test "returns 'No events found' when empty" do
      set_mock_response({:ok, []})
      {:ok, result} = List.execute(%{}, build_context())

      assert result.status == :ok
      assert result.content =~ "No events found"
      assert result.metadata.count == 0
    end

    test "formats event list with count" do
      set_mock_response({:ok, [mock_event(), mock_event(%{id: "evt_def"})]})
      {:ok, result} = List.execute(%{}, build_context())

      assert result.status == :ok
      assert result.content =~ "Found 2 event(s)"
      assert result.metadata.count == 2
    end

    test "includes event summary in output" do
      set_mock_response({:ok, [mock_event()]})
      {:ok, result} = List.execute(%{}, build_context())

      assert result.content =~ "Team Meeting"
      assert result.content =~ "2026-02-19T09:00:00Z"
    end

    test "shows location when present" do
      set_mock_response({:ok, [mock_event(%{location: "Room 42"})]})
      {:ok, result} = List.execute(%{}, build_context())

      assert result.content =~ "Room 42"
    end

    test "uses primary calendar by default" do
      List.execute(%{}, build_context())
      assert_received {:cal_list, "primary", _opts}
    end

    test "uses custom calendar ID" do
      List.execute(%{"calendar" => "team@group.calendar.google.com"}, build_context())
      assert_received {:cal_list, "team@group.calendar.google.com", _opts}
    end
  end

  # ---------------------------------------------------------------
  # Date filtering
  # ---------------------------------------------------------------

  describe "execute/2 date filtering" do
    test "converts --date to time_min/time_max range" do
      List.execute(%{"date" => "2026-02-19"}, build_context())

      assert_received {:cal_list, "primary", opts}
      assert Keyword.get(opts, :time_min) == "2026-02-19T00:00:00Z"
      assert Keyword.get(opts, :time_max) == "2026-02-19T23:59:59Z"
    end

    test "rejects invalid --date format" do
      {:ok, result} = List.execute(%{"date" => "Feb 19 2026"}, build_context())

      assert result.status == :error
      assert result.content =~ "Invalid --date format"
    end

    test "passes --from as time_min" do
      List.execute(%{"from" => "2026-02-19T00:00:00Z"}, build_context())

      assert_received {:cal_list, "primary", opts}
      assert Keyword.get(opts, :time_min) == "2026-02-19T00:00:00Z"
    end

    test "passes --to as time_max" do
      List.execute(%{"to" => "2026-02-28T23:59:59Z"}, build_context())

      assert_received {:cal_list, "primary", opts}
      assert Keyword.get(opts, :time_max) == "2026-02-28T23:59:59Z"
    end

    test "normalizes short --from datetime" do
      List.execute(%{"from" => "2026-02-19 09:00"}, build_context())

      assert_received {:cal_list, "primary", opts}
      assert Keyword.get(opts, :time_min) == "2026-02-19T09:00:00Z"
    end

    test "passes no time filters when no date flags given" do
      List.execute(%{}, build_context())

      assert_received {:cal_list, "primary", opts}
      refute Keyword.has_key?(opts, :time_min)
      refute Keyword.has_key?(opts, :time_max)
    end
  end

  # ---------------------------------------------------------------
  # Limit handling
  # ---------------------------------------------------------------

  describe "execute/2 limit handling" do
    test "uses default limit of 10" do
      List.execute(%{}, build_context())
      assert_received {:cal_list, _, opts}
      assert Keyword.get(opts, :max_results) == 10
    end

    test "passes custom limit" do
      List.execute(%{"limit" => "5"}, build_context())
      assert_received {:cal_list, _, opts}
      assert Keyword.get(opts, :max_results) == 5
    end

    test "clamps limit to max 50" do
      List.execute(%{"limit" => "999"}, build_context())
      assert_received {:cal_list, _, opts}
      assert Keyword.get(opts, :max_results) == 50
    end

    test "clamps limit to min 1" do
      List.execute(%{"limit" => "0"}, build_context())
      assert_received {:cal_list, _, opts}
      assert Keyword.get(opts, :max_results) == 1
    end

    test "uses default for non-numeric limit" do
      List.execute(%{"limit" => "abc"}, build_context())
      assert_received {:cal_list, _, opts}
      assert Keyword.get(opts, :max_results) == 10
    end

    test "handles integer limit" do
      List.execute(%{"limit" => 7}, build_context())
      assert_received {:cal_list, _, opts}
      assert Keyword.get(opts, :max_results) == 7
    end
  end

  # ---------------------------------------------------------------
  # Error handling
  # ---------------------------------------------------------------

  describe "execute/2 error handling" do
    test "wraps Calendar API errors" do
      set_mock_response({:error, %{status: 403, body: "forbidden"}})
      {:ok, result} = List.execute(%{}, build_context())

      assert result.status == :error
      assert result.content =~ "Calendar query failed"
    end
  end

  # ---------------------------------------------------------------
  # No Calendar integration
  # ---------------------------------------------------------------

  describe "execute/2 without Calendar integration" do
    test "returns error when calendar integration is nil" do
      context = build_context(%{integrations: %{}})
      {:ok, result} = List.execute(%{}, context)

      assert result.status == :error
      assert result.content =~ "Google Calendar integration not configured"
    end
  end
end

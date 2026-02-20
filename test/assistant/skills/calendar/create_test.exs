# test/assistant/skills/calendar/create_test.exs
#
# Tests for the calendar.create skill handler. Uses a MockCalendar module
# injected via context.integrations[:calendar] to avoid real API calls.
# Tests parameter validation, datetime normalization, attendee parsing,
# and result formatting.

defmodule Assistant.Skills.Calendar.CreateTest do
  use ExUnit.Case, async: true

  alias Assistant.Skills.Calendar.Create
  alias Assistant.Skills.Context

  # ---------------------------------------------------------------
  # Mock Calendar module
  # ---------------------------------------------------------------

  defmodule MockCalendar do
    @moduledoc false

    def create_event(_token, params, calendar_id) do
      send(self(), {:cal_create, params, calendar_id})

      case Process.get(:mock_cal_create_response) do
        nil ->
          {:ok,
           %{
             id: "evt_123",
             summary: params[:summary],
             html_link: "https://calendar.google.com/event?eid=evt_123"
           }}

        response ->
          response
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
    Process.put(:mock_cal_create_response, response)
  end

  defp valid_flags do
    %{
      "title" => "Team Standup",
      "start" => "2026-02-19T09:00:00Z",
      "end" => "2026-02-19T09:30:00Z"
    }
  end

  # ---------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------

  describe "execute/2 happy path" do
    test "creates event and returns success result" do
      {:ok, result} = Create.execute(valid_flags(), build_context())

      assert result.status == :ok
      assert result.content =~ "Event created successfully"
      assert result.content =~ "evt_123"
      assert result.content =~ "Team Standup"
      assert result.side_effects == [:calendar_event_created]
      assert result.metadata.event_id == "evt_123"
    end

    test "passes correct params to Calendar client" do
      Create.execute(valid_flags(), build_context())

      assert_received {:cal_create, params, "primary"}
      assert params[:summary] == "Team Standup"
      assert params[:start] == "2026-02-19T09:00:00Z"
      assert params[:end] == "2026-02-19T09:30:00Z"
    end

    test "uses custom calendar ID" do
      flags = Map.put(valid_flags(), "calendar", "team@group.calendar.google.com")
      Create.execute(flags, build_context())

      assert_received {:cal_create, _params, "team@group.calendar.google.com"}
    end

    test "includes html_link in output when present" do
      {:ok, result} = Create.execute(valid_flags(), build_context())
      assert result.content =~ "https://calendar.google.com"
    end
  end

  # ---------------------------------------------------------------
  # Datetime normalization
  # ---------------------------------------------------------------

  describe "execute/2 datetime normalization" do
    test "normalizes short datetime to RFC 3339" do
      flags = %{
        "title" => "Meeting",
        "start" => "2026-02-19 09:00",
        "end" => "2026-02-19 10:00"
      }

      Create.execute(flags, build_context())

      assert_received {:cal_create, params, _}
      assert params[:start] == "2026-02-19T09:00:00Z"
      assert params[:end] == "2026-02-19T10:00:00Z"
    end

    test "passes through already-valid RFC 3339 datetime" do
      Create.execute(valid_flags(), build_context())

      assert_received {:cal_create, params, _}
      assert params[:start] == "2026-02-19T09:00:00Z"
    end

    test "passes through non-matching datetime format unchanged" do
      flags = %{
        "title" => "Meeting",
        "start" => "tomorrow at 9am",
        "end" => "tomorrow at 10am"
      }

      Create.execute(flags, build_context())

      assert_received {:cal_create, params, _}
      assert params[:start] == "tomorrow at 9am"
    end
  end

  # ---------------------------------------------------------------
  # Optional fields
  # ---------------------------------------------------------------

  describe "execute/2 optional fields" do
    test "includes description when provided" do
      flags = Map.put(valid_flags(), "description", "Weekly sync meeting")
      Create.execute(flags, build_context())

      assert_received {:cal_create, params, _}
      assert params[:description] == "Weekly sync meeting"
    end

    test "includes location when provided" do
      flags = Map.put(valid_flags(), "location", "Conference Room A")
      Create.execute(flags, build_context())

      assert_received {:cal_create, params, _}
      assert params[:location] == "Conference Room A"
    end

    test "omits optional fields when not provided" do
      Create.execute(valid_flags(), build_context())

      assert_received {:cal_create, params, _}
      refute Map.has_key?(params, :description)
      refute Map.has_key?(params, :location)
    end
  end

  # ---------------------------------------------------------------
  # Attendee parsing
  # ---------------------------------------------------------------

  describe "execute/2 attendee parsing" do
    test "parses comma-separated attendees" do
      flags = Map.put(valid_flags(), "attendees", "alice@example.com, bob@example.com")
      Create.execute(flags, build_context())

      assert_received {:cal_create, params, _}
      assert params[:attendees] == ["alice@example.com", "bob@example.com"]
    end

    test "trims whitespace from attendees" do
      flags = Map.put(valid_flags(), "attendees", " alice@example.com ,  bob@example.com ")
      Create.execute(flags, build_context())

      assert_received {:cal_create, params, _}
      assert params[:attendees] == ["alice@example.com", "bob@example.com"]
    end

    test "skips empty attendee strings" do
      flags = Map.put(valid_flags(), "attendees", "alice@example.com,,bob@example.com,")
      Create.execute(flags, build_context())

      assert_received {:cal_create, params, _}
      assert params[:attendees] == ["alice@example.com", "bob@example.com"]
    end

    test "omits attendees when empty string" do
      flags = Map.put(valid_flags(), "attendees", "")
      Create.execute(flags, build_context())

      assert_received {:cal_create, params, _}
      refute Map.has_key?(params, :attendees)
    end
  end

  # ---------------------------------------------------------------
  # Missing required parameters
  # ---------------------------------------------------------------

  describe "execute/2 missing parameters" do
    test "returns error when --title is missing" do
      flags = Map.delete(valid_flags(), "title")
      {:ok, result} = Create.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "--title"
    end

    test "returns error when --title is empty" do
      flags = Map.put(valid_flags(), "title", "")
      {:ok, result} = Create.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "--title"
    end

    test "returns error when --start is missing" do
      flags = Map.delete(valid_flags(), "start")
      {:ok, result} = Create.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "--start"
    end

    test "returns error when --end is missing" do
      flags = Map.delete(valid_flags(), "end")
      {:ok, result} = Create.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "--end"
    end
  end

  # ---------------------------------------------------------------
  # Calendar API errors
  # ---------------------------------------------------------------

  describe "execute/2 error handling" do
    test "handles Calendar API error" do
      set_mock_response({:error, %{status: 403, body: "forbidden"}})
      {:ok, result} = Create.execute(valid_flags(), build_context())

      assert result.status == :error
      assert result.content =~ "Failed to create event"
    end
  end

  # ---------------------------------------------------------------
  # No Calendar integration
  # ---------------------------------------------------------------

  describe "execute/2 without Calendar integration" do
    test "returns error when calendar integration is nil" do
      context = build_context(%{integrations: %{}})
      {:ok, result} = Create.execute(valid_flags(), context)

      assert result.status == :error
      assert result.content =~ "Google Calendar integration not configured"
    end
  end
end

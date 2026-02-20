# test/assistant/skills/calendar/update_test.exs
#
# Tests for the calendar.update skill handler. Uses a MockCalendar module
# injected via context.integrations[:calendar] to avoid real API calls.
# Tests required --id parameter, sparse updates, and error handling.

defmodule Assistant.Skills.Calendar.UpdateTest do
  use ExUnit.Case, async: true

  alias Assistant.Skills.Calendar.Update
  alias Assistant.Skills.Context

  # ---------------------------------------------------------------
  # Mock Calendar module
  # ---------------------------------------------------------------

  defmodule MockCalendar do
    @moduledoc false

    def update_event(_token, event_id, params, calendar_id) do
      send(self(), {:cal_update, event_id, params, calendar_id})

      case Process.get(:mock_cal_update_response) do
        nil ->
          {:ok,
           %{
             id: event_id,
             summary: params[:summary] || "Existing Event"
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
    Process.put(:mock_cal_update_response, response)
  end

  # ---------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------

  describe "execute/2 happy path" do
    test "updates event and returns success" do
      flags = %{"id" => "evt_123", "title" => "New Title"}
      {:ok, result} = Update.execute(flags, build_context())

      assert result.status == :ok
      assert result.content =~ "Event updated successfully"
      assert result.content =~ "evt_123"
      assert result.content =~ "New Title"
      assert result.side_effects == [:calendar_event_updated]
      assert result.metadata.event_id == "evt_123"
    end

    test "passes correct params to Calendar client" do
      flags = %{"id" => "evt_123", "title" => "Updated Meeting"}
      Update.execute(flags, build_context())

      assert_received {:cal_update, "evt_123", params, "primary"}
      assert params[:summary] == "Updated Meeting"
    end

    test "uses custom calendar ID" do
      flags = %{
        "id" => "evt_123",
        "title" => "Title",
        "calendar" => "team@group.calendar.google.com"
      }

      Update.execute(flags, build_context())

      assert_received {:cal_update, "evt_123", _params, "team@group.calendar.google.com"}
    end
  end

  # ---------------------------------------------------------------
  # Sparse updates
  # ---------------------------------------------------------------

  describe "execute/2 sparse updates" do
    test "only includes changed fields in params" do
      flags = %{"id" => "evt_123", "title" => "New Title"}
      Update.execute(flags, build_context())

      assert_received {:cal_update, _, params, _}
      assert params[:summary] == "New Title"
      refute Map.has_key?(params, :start)
      refute Map.has_key?(params, :end)
      refute Map.has_key?(params, :description)
    end

    test "includes description when provided" do
      flags = %{"id" => "evt_123", "description" => "Updated description"}
      Update.execute(flags, build_context())

      assert_received {:cal_update, _, params, _}
      assert params[:description] == "Updated description"
    end

    test "includes location when provided" do
      flags = %{"id" => "evt_123", "location" => "Room B"}
      Update.execute(flags, build_context())

      assert_received {:cal_update, _, params, _}
      assert params[:location] == "Room B"
    end

    test "normalizes short datetime in --start" do
      flags = %{"id" => "evt_123", "start" => "2026-02-20 14:00"}
      Update.execute(flags, build_context())

      assert_received {:cal_update, _, params, _}
      assert params[:start] == "2026-02-20T14:00:00Z"
    end

    test "normalizes short datetime in --end" do
      flags = %{"id" => "evt_123", "end" => "2026-02-20 15:00"}
      Update.execute(flags, build_context())

      assert_received {:cal_update, _, params, _}
      assert params[:end] == "2026-02-20T15:00:00Z"
    end

    test "parses attendees" do
      flags = %{"id" => "evt_123", "attendees" => "alice@example.com, bob@example.com"}
      Update.execute(flags, build_context())

      assert_received {:cal_update, _, params, _}
      assert params[:attendees] == ["alice@example.com", "bob@example.com"]
    end
  end

  # ---------------------------------------------------------------
  # Missing required parameter
  # ---------------------------------------------------------------

  describe "execute/2 missing ID" do
    test "returns error when --id is missing" do
      {:ok, result} = Update.execute(%{"title" => "New"}, build_context())

      assert result.status == :error
      assert result.content =~ "--id"
    end

    test "returns error when --id is empty" do
      {:ok, result} = Update.execute(%{"id" => "", "title" => "New"}, build_context())

      assert result.status == :error
      assert result.content =~ "--id"
    end
  end

  # ---------------------------------------------------------------
  # Error handling
  # ---------------------------------------------------------------

  describe "execute/2 error handling" do
    test "handles Calendar API error" do
      set_mock_response({:error, %{status: 404, body: "not found"}})
      flags = %{"id" => "evt_missing", "title" => "New Title"}
      {:ok, result} = Update.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "Failed to update event"
    end
  end

  # ---------------------------------------------------------------
  # No Calendar integration
  # ---------------------------------------------------------------

  describe "execute/2 without Calendar integration" do
    test "returns error when calendar integration is nil" do
      context = build_context(%{integrations: %{}})
      flags = %{"id" => "evt_123", "title" => "New Title"}
      {:ok, result} = Update.execute(flags, context)

      assert result.status == :error
      assert result.content =~ "Google Calendar integration not configured"
    end
  end
end

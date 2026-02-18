# lib/assistant/skills/calendar/update.ex — Handler for calendar.update skill.
#
# Updates an existing Google Calendar event. Only non-nil flags are included
# in the update params sent to the Calendar API client.
#
# Related files:
#   - lib/assistant/integrations/google/calendar.ex (Calendar API client)
#   - lib/assistant/skills/handler.ex (behaviour)
#   - priv/skills/calendar/update.md (skill definition)

defmodule Assistant.Skills.Calendar.Update do
  @moduledoc """
  Skill handler for updating Google Calendar events.

  Builds a sparse update map from CLI flags (only non-nil fields) and
  delegates to the Calendar client's update_event/3.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Skills.Result
  alias Assistant.Integrations.Google.Calendar

  @datetime_short_regex ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/

  @impl true
  def execute(flags, context) do
    calendar = Map.get(context.integrations, :calendar, Calendar)
    calendar_id = Map.get(flags, "calendar", "primary")
    event_id = Map.get(flags, "id")

    if is_nil(event_id) or event_id == "" do
      {:ok, %Result{status: :error, content: "Missing required flag: --id"}}
    else
      params = build_params(flags)
      update_event(calendar, event_id, params, calendar_id)
    end
  end

  defp update_event(calendar, event_id, params, calendar_id) do
    case calendar.update_event(event_id, params, calendar_id) do
      {:ok, event} ->
        content = format_confirmation(event)

        {:ok, %Result{
          status: :ok,
          content: content,
          side_effects: [:calendar_event_updated],
          metadata: %{event_id: event[:id]}
        }}

      {:error, reason} ->
        {:ok, %Result{status: :error, content: "Failed to update event: #{inspect(reason)}"}}
    end
  end

  defp build_params(flags) do
    %{}
    |> maybe_put(:summary, Map.get(flags, "title"))
    |> maybe_put(:start, normalize_datetime(Map.get(flags, "start")))
    |> maybe_put(:end, normalize_datetime(Map.get(flags, "end")))
    |> maybe_put(:description, Map.get(flags, "description"))
    |> maybe_put(:location, Map.get(flags, "location"))
    |> maybe_put(:attendees, parse_attendees(Map.get(flags, "attendees")))
  end

  defp normalize_datetime(nil), do: nil

  defp normalize_datetime(dt) do
    if Regex.match?(@datetime_short_regex, dt) do
      String.replace(dt, " ", "T") <> ":00Z"
    else
      dt
    end
  end

  defp parse_attendees(nil), do: nil
  defp parse_attendees(""), do: nil

  defp parse_attendees(str) do
    str |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_confirmation(event) do
    title = event[:summary] || "(No title)"
    "Event updated successfully.\nID: #{event[:id]}\nTitle: #{title}"
  end
end

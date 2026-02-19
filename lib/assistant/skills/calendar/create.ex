# lib/assistant/skills/calendar/create.ex — Handler for calendar.create skill.
#
# Creates a new Google Calendar event with title, start/end times,
# optional description, location, and attendees.
#
# Related files:
#   - lib/assistant/integrations/google/calendar.ex (Calendar API client)
#   - lib/assistant/skills/handler.ex (behaviour)
#   - priv/skills/calendar/create.md (skill definition)

defmodule Assistant.Skills.Calendar.Create do
  @moduledoc """
  Skill handler for creating Google Calendar events.

  Parses CLI flags into Calendar API params, normalizes datetime formats,
  and returns a confirmation with the new event ID and link.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Skills.Result

  @datetime_short_regex ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/

  @impl true
  def execute(flags, context) do
    case Map.get(context.integrations, :calendar) do
      nil ->
        {:ok, %Result{status: :error, content: "Google Calendar integration not configured."}}

      calendar ->
        calendar_id = Map.get(flags, "calendar", "primary")

        case build_params(flags) do
          {:ok, params} -> create_event(calendar, params, calendar_id)
          {:error, message} -> {:ok, %Result{status: :error, content: message}}
        end
    end
  end

  defp create_event(calendar, params, calendar_id) do
    case calendar.create_event(params, calendar_id) do
      {:ok, event} ->
        content = format_confirmation(event)

        {:ok, %Result{
          status: :ok,
          content: content,
          side_effects: [:calendar_event_created],
          metadata: %{event_id: event[:id]}
        }}

      {:error, reason} ->
        {:ok, %Result{status: :error, content: "Failed to create event: #{inspect(reason)}"}}
    end
  end

  defp build_params(flags) do
    title = Map.get(flags, "title")
    start_dt = Map.get(flags, "start")
    end_dt = Map.get(flags, "end")

    cond do
      is_nil(title) or title == "" ->
        {:error, "Missing required flag: --title"}

      is_nil(start_dt) or start_dt == "" ->
        {:error, "Missing required flag: --start"}

      is_nil(end_dt) or end_dt == "" ->
        {:error, "Missing required flag: --end"}

      true ->
        params =
          %{summary: title, start: normalize_datetime(start_dt), end: normalize_datetime(end_dt)}
          |> maybe_put(:description, Map.get(flags, "description"))
          |> maybe_put(:location, Map.get(flags, "location"))
          |> maybe_put(:attendees, parse_attendees(Map.get(flags, "attendees")))

        {:ok, params}
    end
  end

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
    result = str |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    if result == [], do: nil, else: result
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_confirmation(event) do
    link = if event[:html_link], do: "\nLink: #{event[:html_link]}", else: ""

    "Event created successfully.\n" <>
      "ID: #{event[:id]}\n" <>
      "Title: #{event[:summary]}#{link}"
  end
end

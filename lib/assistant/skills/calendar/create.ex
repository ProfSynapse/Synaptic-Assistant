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

  alias Assistant.Skills.Calendar.Helpers
  alias Assistant.Skills.Result

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

        {:ok,
         %Result{
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
          %{
            summary: title,
            start: Helpers.normalize_datetime(start_dt),
            end: Helpers.normalize_datetime(end_dt)
          }
          |> Helpers.maybe_put(:description, Map.get(flags, "description"))
          |> Helpers.maybe_put(:location, Map.get(flags, "location"))
          |> Helpers.maybe_put(:attendees, Helpers.parse_attendees(Map.get(flags, "attendees")))

        {:ok, params}
    end
  end

  defp format_confirmation(event) do
    link = if event[:html_link], do: "\nLink: #{event[:html_link]}", else: ""

    "Event created successfully.\n" <>
      "ID: #{event[:id]}\n" <>
      "Title: #{event[:summary]}#{link}"
  end
end

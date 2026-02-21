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

  alias Assistant.Skills.Calendar.Helpers
  alias Assistant.Skills.Result

  @impl true
  def execute(flags, context) do
    case Map.get(context.integrations, :calendar) do
      nil ->
        {:ok, %Result{status: :error, content: "Google Calendar integration not configured."}}

      calendar ->
        case context.metadata[:google_token] do
          nil ->
            {:ok,
             %Result{
               status: :error,
               content: "Google authentication required. Please connect your Google account."
             }}

          token ->
            calendar_id = Map.get(flags, "calendar", "primary")
            event_id = Map.get(flags, "id")

            if is_nil(event_id) or event_id == "" do
              {:ok, %Result{status: :error, content: "Missing required flag: --id"}}
            else
              params = build_params(flags)
              update_event(calendar, token, event_id, params, calendar_id)
            end
        end
    end
  end

  defp update_event(calendar, token, event_id, params, calendar_id) do
    case calendar.update_event(token, event_id, params, calendar_id) do
      {:ok, event} ->
        content = format_confirmation(event)

        {:ok,
         %Result{
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
    |> Helpers.maybe_put(:summary, Map.get(flags, "title"))
    |> Helpers.maybe_put(:start, Helpers.normalize_datetime(Map.get(flags, "start")))
    |> Helpers.maybe_put(:end, Helpers.normalize_datetime(Map.get(flags, "end")))
    |> Helpers.maybe_put(:description, Map.get(flags, "description"))
    |> Helpers.maybe_put(:location, Map.get(flags, "location"))
    |> Helpers.maybe_put(:attendees, Helpers.parse_attendees(Map.get(flags, "attendees")))
  end

  defp format_confirmation(event) do
    title = event[:summary] || "(No title)"
    "Event updated successfully.\nID: #{event[:id]}\nTitle: #{title}"
  end
end

# lib/assistant/skills/calendar/list.ex — Handler for calendar.list skill.
#
# Lists Google Calendar events within a date range. Supports filtering by
# specific date, date range, result limit, and calendar ID.
#
# Related files:
#   - lib/assistant/integrations/google/calendar.ex (Calendar API client)
#   - lib/assistant/skills/handler.ex (behaviour)
#   - priv/skills/calendar/list.md (skill definition)

defmodule Assistant.Skills.Calendar.List do
  @moduledoc """
  Skill handler for listing Google Calendar events.

  Builds Calendar API query options from CLI flags and returns a formatted
  event list for LLM context.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Skills.Calendar.Helpers
  alias Assistant.Skills.Result

  @date_regex ~r/^\d{4}-\d{2}-\d{2}$/

  @impl true
  def execute(flags, context) do
    case Map.get(context.integrations, :calendar) do
      nil ->
        {:ok, %Result{status: :error, content: "Google Calendar integration not configured."}}

      calendar ->
        calendar_id = Map.get(flags, "calendar", "primary")
        limit = Helpers.parse_limit(Map.get(flags, "limit"))

        case build_opts(flags) do
          {:ok, opts} ->
            opts = Keyword.put(opts, :max_results, limit)
            list_events(calendar, calendar_id, opts)

          {:error, reason} ->
            {:ok, %Result{status: :error, content: reason}}
        end
    end
  end

  defp list_events(calendar, calendar_id, opts) do
    case calendar.list_events(calendar_id, opts) do
      {:ok, []} ->
        {:ok, %Result{status: :ok, content: "No events found.", metadata: %{count: 0}}}

      {:ok, events} ->
        content = format_event_list(events)
        {:ok, %Result{status: :ok, content: content, metadata: %{count: length(events)}}}

      {:error, reason} ->
        {:ok, %Result{status: :error, content: "Calendar query failed: #{inspect(reason)}"}}
    end
  end

  defp build_opts(flags) do
    date = Map.get(flags, "date")
    from = Map.get(flags, "from")
    to = Map.get(flags, "to")

    cond do
      date != nil ->
        case normalize_date_range(date) do
          {:ok, time_min, time_max} -> {:ok, [time_min: time_min, time_max: time_max]}
          {:error, _} = err -> err
        end

      from != nil or to != nil ->
        opts = []
        opts = if from, do: [{:time_min, Helpers.normalize_datetime(from)} | opts], else: opts
        opts = if to, do: [{:time_max, Helpers.normalize_datetime(to)} | opts], else: opts
        {:ok, opts}

      true ->
        {:ok, []}
    end
  end

  defp normalize_date_range(date) do
    if Regex.match?(@date_regex, date) do
      {:ok, date <> "T00:00:00Z", date <> "T23:59:59Z"}
    else
      {:error, "Invalid --date format. Expected YYYY-MM-DD, got: #{date}"}
    end
  end

  defp format_event_list(events) do
    header = "Found #{length(events)} event(s):\n"
    rows = events |> Enum.map(&format_event_row/1) |> Enum.join("\n")
    header <> rows
  end

  defp format_event_row(event) do
    title = event[:summary] || "(No title)"
    start_time = event[:start] || "?"
    end_time = event[:end] || "?"
    location = if event[:location], do: " | Location: #{event[:location]}", else: ""

    "- #{title} | #{start_time} - #{end_time}#{location}"
  end

end

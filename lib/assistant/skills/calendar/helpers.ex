# lib/assistant/skills/calendar/helpers.ex — Shared utilities for calendar skill handlers.
#
# Extracts common functions (datetime normalization, attendee parsing, optional
# map insertion, limit parsing) that were previously duplicated across
# create.ex, update.ex, and list.ex.
#
# Related files:
#   - lib/assistant/skills/calendar/create.ex (uses normalize_datetime, parse_attendees, maybe_put)
#   - lib/assistant/skills/calendar/update.ex (uses normalize_datetime, parse_attendees, maybe_put)
#   - lib/assistant/skills/calendar/list.ex   (uses normalize_datetime, parse_limit)
#   - lib/assistant/skills/helpers.ex         (cross-domain parse_limit)

defmodule Assistant.Skills.Calendar.Helpers do
  @moduledoc false

  alias Assistant.Skills.Helpers, as: SkillsHelpers

  @datetime_short_regex ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/
  @default_limit 10
  @max_limit 50

  @doc "Returns the compiled regex for matching short datetime strings (YYYY-MM-DD HH:MM)."
  def datetime_short_regex, do: @datetime_short_regex

  @doc """
  Normalizes a short datetime string ("YYYY-MM-DD HH:MM") into ISO 8601 format.
  Returns `nil` unchanged for nil input. Non-matching strings pass through as-is.
  """
  def normalize_datetime(nil), do: nil

  def normalize_datetime(dt) do
    if Regex.match?(@datetime_short_regex, dt) do
      String.replace(dt, " ", "T") <> ":00Z"
    else
      dt
    end
  end

  @doc """
  Parses a comma-separated attendees string into a list of trimmed email addresses.
  Returns `nil` for nil, empty string, or when all entries are blank.
  """
  def parse_attendees(nil), do: nil
  def parse_attendees(""), do: nil

  def parse_attendees(str) do
    result = str |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    if result == [], do: nil, else: result
  end

  @doc """
  Conditionally puts a key-value pair into a map. Skips nil values.
  """
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Parses a limit value for calendar queries. Delegates to the cross-domain
  `Skills.Helpers.parse_limit/3` with calendar-specific defaults (10, max 50).
  """
  def parse_limit(value), do: SkillsHelpers.parse_limit(value, @default_limit, @max_limit)
end

# lib/assistant/skills/helpers.ex — Cross-domain utilities shared by all skill families.
#
# Houses generic helper functions (e.g. parse_limit) that appear in multiple
# skill domains (email, calendar, files). Domain-specific helpers modules
# delegate here to avoid duplication across skill families.
#
# Related files:
#   - lib/assistant/skills/email/helpers.ex   (email-specific helpers)
#   - lib/assistant/skills/calendar/helpers.ex (calendar-specific helpers)
#   - lib/assistant/skills/workflow/helpers.ex (workflow-specific helpers)
#   - lib/assistant/skills/files/search.ex     (file search, uses parse_limit)

defmodule Assistant.Skills.Helpers do
  @moduledoc false

  @doc """
  Parses a limit value from CLI flags into a bounded integer.

  Accepts `nil`, a binary string, or an integer. Clamps the result between 1
  and `max`. Falls back to `default` when the value is missing or unparseable.
  """
  def parse_limit(value, default \\ 10, max \\ 50)
  def parse_limit(nil, default, _max), do: default

  def parse_limit(value, default, max) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> min(max(n, 1), max)
      :error -> default
    end
  end

  def parse_limit(value, _default, max) when is_integer(value), do: min(max(value, 1), max)
  def parse_limit(_value, default, _max), do: default
end

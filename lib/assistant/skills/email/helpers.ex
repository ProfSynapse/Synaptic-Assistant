# lib/assistant/skills/email/helpers.ex — Shared utilities for email skill handlers.
#
# Extracts common functions (validation, formatting, parsing) that were
# previously duplicated across send.ex, draft.ex, list.ex, and search.ex.
#
# Related files:
#   - lib/assistant/skills/email/send.ex   (uses has_newlines?, truncate_log)
#   - lib/assistant/skills/email/draft.ex  (uses has_newlines?, truncate_log)
#   - lib/assistant/skills/email/list.ex   (uses parse_limit, full_mode?, truncate)
#   - lib/assistant/skills/email/search.ex (uses parse_limit, full_mode?, truncate)
#   - lib/assistant/skills/helpers.ex      (cross-domain parse_limit)

defmodule Assistant.Skills.Email.Helpers do
  @moduledoc false

  alias Assistant.Skills.Helpers, as: SkillsHelpers

  @default_limit 10
  @max_limit 50

  def has_newlines?(str), do: String.contains?(str, ["\r", "\n"])

  def truncate_log(s) when byte_size(s) <= 50, do: s
  def truncate_log(s), do: String.slice(s, 0, 47) <> "..."

  def truncate(str, max) when byte_size(str) <= max, do: str
  def truncate(str, max), do: String.slice(str, 0, max - 3) <> "..."

  def parse_limit(value), do: SkillsHelpers.parse_limit(value, @default_limit, @max_limit)

  def full_mode?(flags) do
    case Map.get(flags, "full") do
      nil -> false
      "false" -> false
      _ -> true
    end
  end
end

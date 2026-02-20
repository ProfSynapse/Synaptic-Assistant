# lib/assistant/skills/email/search.ex — Handler for email.search skill.
#
# Searches Gmail messages using the Gmail API wrapper. Builds a Gmail query
# string from CLI flags (query, from, to, date range, unread) and returns
# a formatted list. With --full, includes complete message content.
#
# Related files:
#   - lib/assistant/integrations/google/gmail.ex (Gmail API client)
#   - lib/assistant/skills/handler.ex (behaviour)
#   - priv/skills/email/search.md (skill definition)

defmodule Assistant.Skills.Email.Search do
  @moduledoc """
  Skill handler for searching Gmail messages.

  Builds a Gmail query string from CLI flags and returns a formatted
  list. Default mode shows summaries; `--full` includes body content.
  """

  @behaviour Assistant.Skills.Handler

  require Logger

  alias Assistant.Skills.Email.Helpers
  alias Assistant.Skills.Result
  @divider "\n\n---\n\n"

  @impl true
  def execute(flags, context) do
    case Map.get(context.integrations, :gmail) do
      nil ->
        {:ok, %Result{status: :error, content: "Gmail integration not configured."}}

      gmail ->
        token = context.google_token
        limit = Helpers.parse_limit(Map.get(flags, "limit"))
        query = build_query(flags)
        full? = Helpers.full_mode?(flags)
        search_messages(gmail, token, query, limit, full?)
    end
  end

  defp search_messages(gmail, token, query, limit, full?) do
    case gmail.search_messages(token, query, limit: limit) do
      {:ok, []} ->
        {:ok,
         %Result{
           status: :ok,
           content: "No messages found matching the given criteria.",
           metadata: %{count: 0}
         }}

      {:ok, messages} ->
        content = format_output(messages, full?)
        {:ok, %Result{status: :ok, content: content, metadata: %{count: length(messages)}}}

      {:error, reason} ->
        {:ok, %Result{status: :error, content: "Gmail search failed: #{inspect(reason)}"}}
    end
  end

  defp format_output(messages, false) do
    header = "Found #{length(messages)} message(s):\n"
    rows = Enum.map_join(messages, "\n", &format_summary_row/1)
    header <> rows
  end

  defp format_output(messages, true) do
    header = "Found #{length(messages)} message(s):\n"
    rows = Enum.map_join(messages, @divider, &format_full/1)
    header <> rows
  end

  defp format_summary_row(msg) do
    subject = Helpers.truncate(msg[:subject] || "(no subject)", 80)
    from = msg[:from] || "unknown"
    date = msg[:date] || ""
    snippet = Helpers.truncate(msg[:snippet] || "", 100)
    "- [#{msg[:id]}] #{subject}\n  From: #{from} | Date: #{date}\n  #{snippet}"
  end

  defp format_full(msg) do
    headers = [
      "Subject: #{msg[:subject] || "(no subject)"}",
      "From: #{msg[:from] || "unknown"}",
      "To: #{msg[:to] || "unknown"}",
      "Date: #{msg[:date] || "unknown"}"
    ]

    body = msg[:body] || "(no body content)"
    Enum.join(headers, "\n") <> "\n\n" <> body
  end

  defp build_query(flags) do
    [
      {nil, Map.get(flags, "query")},
      {"from", Map.get(flags, "from")},
      {"to", Map.get(flags, "to")},
      {"after", Map.get(flags, "after")},
      {"before", Map.get(flags, "before")}
    ]
    |> Enum.reduce([], fn
      {_, nil}, acc -> acc
      {_, ""}, acc -> acc
      {nil, val}, acc -> acc ++ [val]
      {key, val}, acc -> acc ++ ["#{key}:#{val}"]
    end)
    |> maybe_add_unread(Map.get(flags, "unread"))
    |> Enum.join(" ")
  end

  defp maybe_add_unread(parts, nil), do: parts
  defp maybe_add_unread(parts, "false"), do: parts
  defp maybe_add_unread(parts, _), do: parts ++ ["is:unread"]
end

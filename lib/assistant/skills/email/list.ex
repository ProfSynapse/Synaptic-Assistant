# lib/assistant/skills/email/list.ex — Handler for email.list skill.
#
# Lists recent emails from a Gmail label (default INBOX). Fetches message
# IDs via list_messages, then resolves each via get_message. Supports
# label filtering, unread-only mode, and --full for complete content.
#
# Related files:
#   - lib/assistant/integrations/google/gmail.ex (Gmail API client)
#   - lib/assistant/skills/handler.ex (behaviour)
#   - priv/skills/email/list.md (skill definition)

defmodule Assistant.Skills.Email.List do
  @moduledoc """
  Skill handler for listing recent Gmail messages.

  Fetches message IDs from a label, resolves each to get headers,
  and returns a formatted index. With `--full`, includes body content.
  """

  @behaviour Assistant.Skills.Handler

  require Logger

  alias Assistant.Skills.Result

  @default_limit 10
  @max_limit 50
  @divider "\n\n---\n\n"

  @impl true
  def execute(flags, context) do
    case Map.get(context.integrations, :gmail) do
      nil ->
        {:ok, %Result{status: :error, content: "Gmail integration not configured."}}

      gmail ->
        limit = parse_limit(Map.get(flags, "limit"))
        query = build_query(flags)
        full? = full_mode?(flags)
        list_messages(gmail, query, limit, full?)
    end
  end

  defp list_messages(gmail, query, limit, full?) do
    case gmail.list_messages("me", query, max_results: limit) do
      {:ok, []} ->
        {:ok, %Result{status: :ok, content: "No messages found.", metadata: %{count: 0}}}

      {:ok, ids} ->
        messages = resolve_messages(gmail, ids)
        content = format_output(messages, full?)
        {:ok, %Result{status: :ok, content: content, metadata: %{count: length(messages)}}}

      {:error, reason} ->
        {:ok, %Result{status: :error, content: "Failed to list messages: #{inspect(reason)}"}}
    end
  end

  defp resolve_messages(gmail, ids) do
    Enum.reduce(ids, [], fn %{id: id}, acc ->
      case gmail.get_message(id) do
        {:ok, msg} -> [msg | acc]
        {:error, reason} ->
          Logger.warning("Email list: skipping message", message_id: id, error: inspect(reason))
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp format_output(messages, false) do
    header = "Showing #{length(messages)} message(s):\n"
    rows = messages |> Enum.with_index(1) |> Enum.map_join("\n", &format_summary_row/1)
    header <> rows
  end

  defp format_output(messages, true) do
    header = "Showing #{length(messages)} message(s):\n"
    rows = Enum.map_join(messages, @divider, &format_full/1)
    header <> rows
  end

  defp format_summary_row({msg, index}) do
    subject = truncate(msg[:subject] || "(no subject)", 70)
    from = msg[:from] || "unknown"
    date = msg[:date] || ""
    "#{index}. [#{msg[:id]}] #{subject}\n   From: #{from} | Date: #{date}"
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
    label = Map.get(flags, "label", "INBOX")
    parts = ["label:#{label}"]
    parts = if unread?(flags), do: parts ++ ["is:unread"], else: parts
    Enum.join(parts, " ")
  end

  defp unread?(flags) do
    case Map.get(flags, "unread") do
      nil -> false
      "false" -> false
      _ -> true
    end
  end

  defp full_mode?(flags) do
    case Map.get(flags, "full") do
      nil -> false
      "false" -> false
      _ -> true
    end
  end

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max - 3) <> "..."

  defp parse_limit(nil), do: @default_limit
  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, _} -> min(max(n, 1), @max_limit)
      :error -> @default_limit
    end
  end
  defp parse_limit(limit) when is_integer(limit), do: min(max(limit, 1), @max_limit)
  defp parse_limit(_), do: @default_limit
end

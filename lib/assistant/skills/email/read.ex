# lib/assistant/skills/email/read.ex — Handler for email.read skill.
#
# Retrieves one or more Gmail messages by ID via the Gmail API wrapper
# and returns formatted email content (headers + body). Supports
# comma-separated IDs for batch reading.
#
# Related files:
#   - lib/assistant/integrations/google/gmail.ex (Gmail API client)
#   - lib/assistant/skills/handler.ex (behaviour)
#   - priv/skills/email/read.md (skill definition)

defmodule Assistant.Skills.Email.Read do
  @moduledoc """
  Skill handler for reading Gmail messages by ID.

  Supports single or comma-separated IDs. Fetches each message and
  returns formatted headers and body text, separated by dividers.
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
        raw_id = Map.get(flags, "id")

        if is_nil(raw_id) || raw_id == "" do
          {:ok, %Result{status: :error, content: "Missing required parameter: --id (message ID)."}}
        else
          ids = parse_ids(raw_id)
          fetch_messages(gmail, token, ids)
        end
    end
  end

  defp parse_ids(raw) do
    raw
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp fetch_messages(gmail, token, ids) do
    results = Enum.map(ids, &fetch_one(gmail, token, &1))
    content = Enum.map_join(results, @divider, &elem(&1, 1))
    all_ids = Enum.map(results, &elem(&1, 0))
    {:ok, %Result{status: :ok, content: content, metadata: %{message_ids: all_ids}}}
  end

  defp fetch_one(gmail, token, id) do
    case gmail.get_message(token, id) do
      {:ok, msg} ->
        Logger.info("Email read", message_id: id, subject: Helpers.truncate_log(msg[:subject] || "(none)"))
        {id, format_message(msg)}

      {:error, :not_found} ->
        {id, "[Error] Message not found: #{id}"}

      {:error, reason} ->
        {id, "[Error] Failed to read message #{id}: #{inspect(reason)}"}
    end
  end

  defp format_message(msg) do
    header_lines = [
      "Subject: #{msg[:subject] || "(no subject)"}",
      "From: #{msg[:from] || "unknown"}",
      "To: #{msg[:to] || "unknown"}",
      "Date: #{msg[:date] || "unknown"}"
    ]

    body = msg[:body] || "(no body content)"
    Enum.join(header_lines, "\n") <> "\n\n" <> body
  end

end

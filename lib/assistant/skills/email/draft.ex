# lib/assistant/skills/email/draft.ex — Handler for email.draft skill.
#
# Creates a Gmail draft (not sent) via the Gmail API wrapper. Validates
# header fields to prevent injection, then delegates to Gmail.create_draft/4.
# This is a read-only skill — drafts are saved locally, not sent.
#
# Related files:
#   - lib/assistant/integrations/google/gmail.ex (Gmail API client)
#   - lib/assistant/skills/handler.ex (behaviour)
#   - priv/skills/email/draft.md (skill definition)

defmodule Assistant.Skills.Email.Draft do
  @moduledoc """
  Skill handler for creating Gmail drafts.

  Validates required fields and header safety, then creates the draft.
  Returns confirmation with the draft ID.
  """

  @behaviour Assistant.Skills.Handler

  require Logger

  alias Assistant.Skills.Result

  @impl true
  def execute(flags, context) do
    case Map.get(context.integrations, :gmail) do
      nil ->
        {:ok, %Result{status: :error, content: "Gmail integration not configured."}}

      gmail ->
        case validate_params(flags) do
          {:ok, params} -> create_draft(gmail, params)
          {:error, message} -> {:ok, %Result{status: :error, content: message}}
        end
    end
  end

  defp validate_params(flags) do
    to = Map.get(flags, "to")
    subject = Map.get(flags, "subject")
    body = Map.get(flags, "body")
    cc = Map.get(flags, "cc")

    cond do
      is_nil(to) || to == "" ->
        {:error, "Missing required parameter: --to (recipient email)."}

      is_nil(subject) || subject == "" ->
        {:error, "Missing required parameter: --subject (email subject)."}

      is_nil(body) || body == "" ->
        {:error, "Missing required parameter: --body (email body)."}

      has_newlines?(to) ->
        {:error, "Invalid --to: must not contain newlines."}

      has_newlines?(subject) ->
        {:error, "Invalid --subject: must not contain newlines."}

      cc != nil && has_newlines?(cc) ->
        {:error, "Invalid --cc: must not contain newlines."}

      true ->
        {:ok, %{to: to, subject: subject, body: body, cc: cc}}
    end
  end

  defp create_draft(gmail, %{to: to, subject: subject, body: body, cc: cc}) do
    opts = if cc, do: [cc: cc], else: []

    case gmail.create_draft(to, subject, body, opts) do
      {:ok, draft} ->
        Logger.info("Draft created",
          draft_id: draft[:id],
          subject: truncate_log(subject)
        )

        {:ok, %Result{
          status: :ok,
          content: "Draft created successfully.\nTo: #{to}\nSubject: #{subject}\nDraft ID: #{draft[:id]}",
          metadata: %{draft_id: draft[:id], to: to}
        }}

      {:error, :header_injection} ->
        {:ok, %Result{status: :error, content: "Draft rejected: header injection detected."}}

      {:error, reason} ->
        {:ok, %Result{status: :error, content: "Failed to create draft: #{inspect(reason)}"}}
    end
  end

  defp has_newlines?(str), do: String.contains?(str, ["\r", "\n"])

  defp truncate_log(s) when byte_size(s) <= 50, do: s
  defp truncate_log(s), do: String.slice(s, 0, 47) <> "..."
end

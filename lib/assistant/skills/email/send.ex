# lib/assistant/skills/email/send.ex — Handler for email.send skill.
#
# Sends an email via the Gmail API wrapper. Validates header fields to
# prevent injection, then delegates to Gmail.send_message/4. This is a
# mutating skill — the markdown definition includes a confirmation note.
#
# Related files:
#   - lib/assistant/integrations/google/gmail.ex (Gmail API client)
#   - lib/assistant/skills/handler.ex (behaviour)
#   - priv/skills/email/send.md (skill definition)

defmodule Assistant.Skills.Email.Send do
  @moduledoc """
  Skill handler for sending email via Gmail.

  Validates required fields and header safety, then sends the message.
  Returns confirmation with the sent message ID.
  """

  @behaviour Assistant.Skills.Handler

  require Logger

  alias Assistant.Skills.Email.Helpers
  alias Assistant.Skills.Result

  @impl true
  def execute(flags, context) do
    case Map.get(context.integrations, :gmail) do
      nil ->
        {:ok, %Result{status: :error, content: "Gmail integration not configured."}}

      gmail ->
        case validate_params(flags) do
          {:ok, params} -> send_email(gmail, params)
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

      Helpers.has_newlines?(to) ->
        {:error, "Invalid --to: must not contain newlines."}

      Helpers.has_newlines?(subject) ->
        {:error, "Invalid --subject: must not contain newlines."}

      cc != nil && Helpers.has_newlines?(cc) ->
        {:error, "Invalid --cc: must not contain newlines."}

      true ->
        {:ok, %{to: to, subject: subject, body: body, cc: cc}}
    end
  end

  defp send_email(gmail, %{to: to, subject: subject, body: body, cc: cc}) do
    opts = if cc, do: [cc: cc], else: []

    case gmail.send_message(to, subject, body, opts) do
      {:ok, sent} ->
        Logger.info("Email sent",
          message_id: sent[:id],
          subject: Helpers.truncate_log(subject)
        )

        {:ok, %Result{
          status: :ok,
          content: "Email sent successfully.\nTo: #{to}\nSubject: #{subject}\nMessage ID: #{sent[:id]}",
          side_effects: [:email_sent],
          metadata: %{message_id: sent[:id], to: to}
        }}

      {:error, :header_injection} ->
        {:ok, %Result{status: :error, content: "Email rejected: header injection detected."}}

      {:error, reason} ->
        {:ok, %Result{status: :error, content: "Failed to send email: #{inspect(reason)}"}}
    end
  end

end

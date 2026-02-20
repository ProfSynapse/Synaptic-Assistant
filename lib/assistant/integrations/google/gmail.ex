# lib/assistant/integrations/google/gmail.ex — Google Gmail API wrapper.
#
# Thin wrapper around GoogleApi.Gmail.V1 that normalizes response structs
# into plain maps. All public functions accept an `access_token` as first
# parameter (per-user OAuth or service-account) to create a Tesla connection.
#
# Related files:
#   - lib/assistant/integrations/google/auth.ex (token provider)
#   - lib/assistant/integrations/google/drive.ex (sibling client — same auth pattern)
#   - lib/assistant/skills/email/send.ex (consumer — email.send skill)
#   - lib/assistant/skills/email/draft.ex (consumer — email.draft skill)
#   - lib/assistant/skills/email/list.ex (consumer — email.list skill)
#   - lib/assistant/skills/email/read.ex (consumer — email.read skill)
#   - lib/assistant/skills/email/search.ex (consumer — email.search skill)

defmodule Assistant.Integrations.Google.Gmail do
  @moduledoc """
  Google Gmail API client wrapping `GoogleApi.Gmail.V1`.

  Provides high-level functions for listing, reading, searching, sending,
  and drafting Gmail messages. All public functions that make API calls
  accept an `access_token` string as the first parameter.

  All public functions return normalized plain maps rather than GoogleApi structs,
  making them easier to work with in skill handlers and tests.

  ## Usage

      # List messages
      {:ok, messages} = Gmail.list_messages(token, "is:unread")

      # Read a message
      {:ok, message} = Gmail.get_message(token, "msg_id_123")

      # Send a message
      {:ok, sent} = Gmail.send_message(token, "to@example.com", "Subject", "Body")

      # Create a draft
      {:ok, draft} = Gmail.create_draft(token, "to@example.com", "Subject", "Body")

      # Search messages (list + get)
      {:ok, messages} = Gmail.search_messages(token, "from:boss")
  """

  require Logger

  alias GoogleApi.Gmail.V1.Api.Users
  alias GoogleApi.Gmail.V1.Connection
  alias GoogleApi.Gmail.V1.Model

  @default_limit 10

  @doc """
  List message IDs matching a Gmail search query.

  ## Parameters

    - `access_token` - OAuth2 access token string
    - `query` - Gmail search query string (e.g., `"is:unread"`, `"from:alice"`)
    - `opts` - Optional keyword list:
      - `:max_results` - Max messages returned (default #{@default_limit})
      - `:user_id` - Gmail user ID (default `"me"`)

  ## Returns

    - `{:ok, [%{id, thread_id}]}` on success
    - `{:error, term()}` on failure
  """
  @spec list_messages(String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_messages(access_token, query, opts \\ []) do
    conn = Connection.new(access_token)
    user_id = Keyword.get(opts, :user_id, "me")
    max = Keyword.get(opts, :max_results, @default_limit)

    case Users.gmail_users_messages_list(conn, user_id, q: query, maxResults: max) do
      {:ok, %Model.ListMessagesResponse{messages: messages}} ->
        {:ok, Enum.map(messages || [], &%{id: &1.id, thread_id: &1.threadId})}

      {:error, reason} ->
        Logger.warning("Gmail list_messages failed", query: query, error: inspect(reason))
        {:error, reason}
    end
  end

  @doc """
  Get a full message by ID. Normalizes headers/body into a plain map.

  ## Parameters

    - `access_token` - OAuth2 access token string
    - `message_id` - The Gmail message ID
    - `opts` - Optional keyword list:
      - `:user_id` - Gmail user ID (default `"me"`)

  ## Returns

    - `{:ok, normalized_message_map}` on success
    - `{:error, :not_found | term()}` on failure
  """
  @spec get_message(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_message(access_token, message_id, opts \\ []) do
    conn = Connection.new(access_token)
    user_id = Keyword.get(opts, :user_id, "me")

    case Users.gmail_users_messages_get(conn, user_id, message_id, format: "full") do
      {:ok, %Model.Message{} = msg} ->
        {:ok, normalize_message(msg)}

      {:error, %Tesla.Env{status: 404}} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.warning("Gmail get_message failed",
          message_id: message_id,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  @doc """
  Send an email. Builds RFC 2822, base64url-encodes, sends via Gmail API.
  Rejects newlines in header fields to prevent header injection.

  ## Parameters

    - `access_token` - OAuth2 access token string
    - `to` - Recipient email address
    - `subject` - Email subject line
    - `body` - Email body text
    - `opts` - Optional keyword list:
      - `:from` - Sender address (default `"me"`)
      - `:cc` - CC recipient address

  ## Returns

    - `{:ok, %{id, thread_id}}` on success
    - `{:error, :header_injection | term()}` on failure
  """
  @spec send_message(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_message(access_token, to, subject, body, opts \\ []) do
    cc = Keyword.get(opts, :cc)

    with :ok <- validate_headers(to, subject, cc) do
      conn = Connection.new(access_token)
      raw = build_rfc2822(to, subject, body, opts) |> base64url_encode()

      case Users.gmail_users_messages_send(conn, "me", body: %Model.Message{raw: raw}) do
        {:ok, %Model.Message{} = sent} ->
          Logger.info("Gmail message sent", message_id: sent.id)
          {:ok, %{id: sent.id, thread_id: sent.threadId}}

        {:error, reason} ->
          Logger.warning("Gmail send_message failed", error: inspect(reason))
          {:error, reason}
      end
    end
  end

  @doc """
  Create a draft email. Builds RFC 2822, base64url-encodes, saves as draft via Gmail API.
  Rejects newlines in header fields to prevent header injection.

  ## Parameters

    - `access_token` - OAuth2 access token string
    - `to` - Recipient email address
    - `subject` - Email subject line
    - `body` - Email body text
    - `opts` - Optional keyword list:
      - `:from` - Sender address (default `"me"`)
      - `:cc` - CC recipient address

  ## Returns

    - `{:ok, %{id}}` on success
    - `{:error, :header_injection | term()}` on failure
  """
  @spec create_draft(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create_draft(access_token, to, subject, body, opts \\ []) do
    cc = Keyword.get(opts, :cc)

    with :ok <- validate_headers(to, subject, cc) do
      conn = Connection.new(access_token)
      raw = build_rfc2822(to, subject, body, opts) |> base64url_encode()
      draft_body = %Model.Draft{message: %Model.Message{raw: raw}}

      case Users.gmail_users_drafts_create(conn, "me", body: draft_body) do
        {:ok, %Model.Draft{} = draft} ->
          Logger.info("Gmail draft created", draft_id: draft.id)
          {:ok, %{id: draft.id}}

        {:error, reason} ->
          Logger.warning("Gmail create_draft failed", error: inspect(reason))
          {:error, reason}
      end
    end
  end

  @doc """
  Search messages and return full content. Calls list then get for each.

  ## Parameters

    - `access_token` - OAuth2 access token string
    - `query` - Gmail search query string
    - `opts` - Optional keyword list:
      - `:limit` - Max messages returned (default #{@default_limit})

  ## Returns

    - `{:ok, [normalized_message_map]}` on success
    - `{:error, term()}` on failure
  """
  @spec search_messages(String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search_messages(access_token, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    with {:ok, ids} <- list_messages(access_token, query, max_results: limit) do
      messages =
        Enum.reduce(ids, [], fn %{id: id}, acc ->
          case get_message(access_token, id) do
            {:ok, msg} ->
              [msg | acc]

            {:error, reason} ->
              Logger.warning("Gmail search: skipping message",
                message_id: id,
                error: inspect(reason)
              )

              acc
          end
        end)
        |> Enum.reverse()

      {:ok, messages}
    end
  end

  # -- Private: RFC 2822 --

  defp build_rfc2822(to, subject, body, opts) do
    from = Keyword.get(opts, :from, "me")
    cc = Keyword.get(opts, :cc)

    headers =
      [
        "From: #{from}",
        "To: #{to}",
        "Subject: #{subject}",
        "MIME-Version: 1.0",
        "Content-Type: text/plain; charset=UTF-8"
      ]

    headers = if cc, do: headers ++ ["Cc: #{cc}"], else: headers
    Enum.join(headers, "\r\n") <> "\r\n\r\n" <> body
  end

  defp base64url_encode(data) do
    Base.url_encode64(data, padding: false)
  end

  defp validate_headers(to, subject, cc) do
    fields = [to, subject] ++ if(cc, do: [cc], else: [])

    if Enum.any?(fields, &String.contains?(&1, ["\r", "\n"])) do
      Logger.warning("Gmail header injection blocked", to: inspect(to), subject: inspect(subject))
      {:error, :header_injection}
    else
      :ok
    end
  end

  # -- Private: message normalization --

  defp normalize_message(%Model.Message{} = msg) do
    headers = extract_headers(msg)

    %{
      id: msg.id,
      thread_id: msg.threadId,
      subject: headers["subject"],
      from: headers["from"],
      to: headers["to"],
      date: headers["date"],
      body: extract_body(msg),
      snippet: msg.snippet
    }
  end

  defp extract_headers(%Model.Message{payload: nil}), do: %{}

  defp extract_headers(%Model.Message{payload: p}) do
    (p.headers || [])
    |> Enum.filter(&(&1.name in ~w(Subject From To Date)))
    |> Map.new(&{String.downcase(&1.name), &1.value})
  end

  defp extract_body(%Model.Message{payload: nil}), do: nil

  defp extract_body(%Model.Message{payload: %{mimeType: "text/plain", body: %{data: d}}})
       when is_binary(d),
       do: base64url_decode(d)

  defp extract_body(%Model.Message{payload: %{parts: parts}}) when is_list(parts),
    do: find_text_part(parts)

  defp extract_body(%Model.Message{payload: %{body: %{data: d}}}) when is_binary(d),
    do: base64url_decode(d)

  defp extract_body(_), do: nil

  defp find_text_part(parts) do
    Enum.find_value(parts, fn
      %{mimeType: "text/plain", body: %{data: d}} when is_binary(d) -> base64url_decode(d)
      %{parts: nested} when is_list(nested) -> find_text_part(nested)
      _ -> nil
    end)
  end

  defp base64url_decode(data) do
    padded = data |> String.replace("-", "+") |> String.replace("_", "/") |> pad_base64()

    case Base.decode64(padded) do
      {:ok, decoded} -> decoded
      :error -> data
    end
  end

  defp pad_base64(s) do
    case rem(byte_size(s), 4) do
      0 -> s
      2 -> s <> "=="
      3 -> s <> "="
      _ -> s
    end
  end
end

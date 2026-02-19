# lib/assistant/integrations/google/gmail.ex — Google Gmail API wrapper.
#
# Thin wrapper around GoogleApi.Gmail.V1 that handles Goth authentication
# and normalizes response structs into plain maps. Used by email domain skills.
#
# Related files:
#   - lib/assistant/integrations/google/auth.ex (token provider)
#   - lib/assistant/integrations/google/drive.ex (sibling client — same auth pattern)

defmodule Assistant.Integrations.Google.Gmail do
  @moduledoc """
  Google Gmail API client wrapping `GoogleApi.Gmail.V1`.

  All public functions return normalized plain maps rather than GoogleApi structs.
  Authentication is handled via `Assistant.Integrations.Google.Auth`.
  """

  require Logger

  alias GoogleApi.Gmail.V1.Api.Users
  alias GoogleApi.Gmail.V1.Connection
  alias GoogleApi.Gmail.V1.Model

  @default_limit 10

  @doc "List message IDs matching a Gmail search query. Returns `{:ok, [%{id, thread_id}]}`."
  @spec list_messages(String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_messages(user_id \\ "me", query, opts \\ []) do
    with {:ok, conn} <- get_connection() do
      max = Keyword.get(opts, :max_results, @default_limit)

      case Users.gmail_users_messages_list(conn, user_id, q: query, maxResults: max) do
        {:ok, %Model.ListMessagesResponse{messages: messages}} ->
          {:ok, Enum.map(messages || [], &%{id: &1.id, thread_id: &1.threadId})}

        {:error, reason} ->
          Logger.warning("Gmail list_messages failed", query: query, error: inspect(reason))
          {:error, reason}
      end
    end
  end

  @doc "Get a full message by ID. Normalizes headers/body into a plain map."
  @spec get_message(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_message(message_id, user_id \\ "me", _opts \\ []) do
    with {:ok, conn} <- get_connection() do
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
  end

  @doc """
  Send an email. Builds RFC 2822, base64url-encodes, sends via Gmail API.
  Rejects newlines in header fields to prevent header injection.
  Opts: `:from`, `:cc`.
  """
  @spec send_message(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_message(to, subject, body, opts \\ []) do
    cc = Keyword.get(opts, :cc)

    with :ok <- validate_headers(to, subject, cc),
         {:ok, conn} <- get_connection() do
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
  Opts: `:from`, `:cc`.
  """
  @spec create_draft(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create_draft(to, subject, body, opts \\ []) do
    cc = Keyword.get(opts, :cc)

    with :ok <- validate_headers(to, subject, cc),
         {:ok, conn} <- get_connection() do
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

  @doc "Search messages and return full content. Calls list then get for each. Opts: `:limit`."
  @spec search_messages(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search_messages(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    with {:ok, ids} <- list_messages("me", query, max_results: limit) do
      messages =
        Enum.reduce(ids, [], fn %{id: id}, acc ->
          case get_message(id) do
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

  # -- Private: connection & RFC 2822 --

  defp get_connection do
    case Assistant.Integrations.Google.Auth.token() do
      {:ok, token} -> {:ok, Connection.new(token)}
      {:error, _} = err -> err
    end
  end

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

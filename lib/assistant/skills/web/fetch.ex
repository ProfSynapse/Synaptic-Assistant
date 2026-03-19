defmodule Assistant.Skills.Web.Fetch do
  @moduledoc """
  Skill handler for deterministic web fetches with optional save-to-folder support.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Integrations.Web.{HtmlExtractor, HttpFetcher}
  alias Assistant.Skills.Result
  alias Assistant.Sync.FileManager

  @default_max_chars 8_000
  @max_max_chars 50_000

  @impl true
  def execute(flags, context) do
    fetcher = Map.get(context.integrations, :web_fetcher, HttpFetcher)
    extractor = Map.get(context.integrations, :web_extractor, HtmlExtractor)

    url = Map.get(flags, "url")
    save_to = Map.get(flags, "save_to")
    selector = Map.get(flags, "selector")
    max_chars = parse_max_chars(Map.get(flags, "max_chars"))

    with :ok <- validate_url(url),
         {:ok, fetched} <- fetch_url(fetcher, url, context),
         {:ok, extracted} <- extract_document(fetched, extractor, selector),
         {:ok, saved_files, save_side_effects} <-
           maybe_save(context.user_id, save_to, fetched, extracted) do
      content = format_result(fetched, extracted, max_chars)

      {:ok,
       %Result{
         status: :ok,
         content: content,
         files_produced: saved_files,
         side_effects: save_side_effects,
         metadata: %{
           url: fetched.url,
           final_url: fetched.final_url,
           title: extracted.title,
           content_type: fetched.content_type,
           saved_to: save_to
         }
       }}
    else
      {:error, reason} when is_binary(reason) ->
        {:ok, %Result{status: :error, content: reason}}

      {:error, :invalid_url} ->
        {:ok,
         %Result{
           status: :error,
           content: "The URL is invalid."
         }}

      {:error, :unsupported_scheme} ->
        {:ok,
         %Result{
           status: :error,
           content: "Only http:// and https:// URLs are allowed."
         }}

      {:error, :missing_host} ->
        {:ok,
         %Result{
           status: :error,
           content: "The URL must include a host."
         }}

      {:error, :disallowed_host} ->
        {:ok,
         %Result{
           status: :error,
           content: "Fetching private, local, or otherwise disallowed hosts is not allowed."
         }}

      {:error, :unresolved_host} ->
        {:ok,
         %Result{
           status: :error,
           content: "The URL host could not be resolved."
         }}

      {:error, :robots_disallowed} ->
        {:ok,
         %Result{
           status: :error,
           content: "Fetching this URL is disallowed by robots.txt."
         }}

      {:error, {:robots_error, reason}} ->
        {:ok,
         %Result{
           status: :error,
           content: "Could not verify robots.txt for this URL: #{inspect(reason)}"
         }}

      {:error, {:http_error, status}} ->
        {:ok,
         %Result{
           status: :error,
           content: "The website returned HTTP #{status}."
         }}

      {:error, {:policy_denied, message}} ->
        {:ok, %Result{status: :error, content: "Policy blocked the fetch: #{message}"}}

      {:error, {:policy_requires_approval, message}} ->
        {:ok,
         %Result{
           status: :error,
           content: "This fetch needs admin approval before it can run: #{message}"
         }}

      {:error, {:unsupported_content_type, type}} ->
        {:ok,
         %Result{
           status: :error,
           content: "Unsupported content type: #{type}."
         }}

      {:error, {:body_too_large, max_bytes}} ->
        {:ok,
         %Result{
           status: :error,
           content: "Fetched page exceeds the #{max_bytes} byte limit."
         }}

      {:error, {:too_many_redirects, max_redirects}} ->
        {:ok,
         %Result{
           status: :error,
           content: "The URL redirected too many times (limit: #{max_redirects})."
         }}

      {:error, {:redirect_missing_location, status}} ->
        {:ok,
         %Result{
           status: :error,
           content: "The website returned an invalid redirect response (HTTP #{status})."
         }}

      {:error, reason} ->
        {:ok, %Result{status: :error, content: "Web fetch failed: #{inspect(reason)}"}}
    end
  end

  defp fetch_url(fetcher, url, context) do
    opts =
      []
      |> maybe_put_opt(:user_id, context.user_id)
      |> maybe_put_opt(:workspace_id, Map.get(context, :workspace_id))

    cond do
      function_exported?(fetcher, :fetch, 2) ->
        fetcher.fetch(url, opts)

      function_exported?(fetcher, :fetch, 1) ->
        fetcher.fetch(url)

      true ->
        {:error, :fetcher_not_available}
    end
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp validate_url(url) when is_binary(url) do
    if String.trim(url) == "" do
      {:error, "Missing required parameter: --url."}
    else
      :ok
    end
  end

  defp validate_url(_), do: {:error, "Missing required parameter: --url."}

  defp extract_document(fetched, extractor, selector) do
    if html_content?(fetched.content_type) do
      extractor.extract(fetched.body, selector: selector)
    else
      {:ok, %{title: nil, canonical_url: nil, content: String.trim(fetched.body)}}
    end
  end

  defp maybe_save(_user_id, nil, _fetched, _extracted), do: {:ok, [], []}
  defp maybe_save(_user_id, "", _fetched, _extracted), do: {:ok, [], []}

  defp maybe_save(user_id, save_to, fetched, extracted) when is_binary(user_id) do
    content = build_saved_markdown(fetched, extracted)

    case FileManager.write_file(user_id, save_to, content) do
      {:ok, _path} ->
        {:ok,
         [
           %{
             path: save_to,
             name: Path.basename(save_to),
             mime_type: "text/markdown"
           }
         ], [:file_saved]}

      {:error, :path_not_allowed} ->
        {:error, "The save path is not allowed."}

      {:error, reason} ->
        {:error, "Failed to save fetched page: #{inspect(reason)}"}
    end
  end

  defp maybe_save(_user_id, _save_to, _fetched, _extracted) do
    {:error, "User context is required to save fetched content."}
  end

  defp format_result(fetched, extracted, max_chars) do
    title = extracted.title || fetched.final_url
    full_text = extracted.content || ""
    {display_text, truncated?} = truncate(full_text, max_chars)

    truncation_note =
      if truncated?,
        do:
          "\n\n[Truncated at #{max_chars} characters. Use --save_to to preserve the full page.]",
        else: ""

    """
    ## #{title}

    Source: #{fetched.final_url}
    Content-Type: #{fetched.content_type || "unknown"}
    Fetched At: #{DateTime.to_iso8601(fetched.fetched_at)}

    #{display_text}#{truncation_note}
    """
    |> String.trim()
  end

  defp build_saved_markdown(fetched, extracted) do
    title = extracted.title || fetched.final_url

    [
      "---",
      "title: #{yaml_escape(title)}",
      "source_url: #{yaml_escape(fetched.url)}",
      "final_url: #{yaml_escape(fetched.final_url)}",
      "fetched_at: #{DateTime.to_iso8601(fetched.fetched_at)}",
      "content_type: #{yaml_escape(fetched.content_type || "unknown")}",
      "---",
      "",
      "# #{title}",
      "",
      extracted.content || fetched.body
    ]
    |> Enum.join("\n")
  end

  defp truncate(text, max_chars) do
    if String.length(text) > max_chars do
      {String.slice(text, 0, max_chars), true}
    else
      {text, false}
    end
  end

  defp parse_max_chars(value) when is_integer(value),
    do: min(max(value, 500), @max_max_chars)

  defp parse_max_chars(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parse_max_chars(parsed)
      :error -> @default_max_chars
    end
  end

  defp parse_max_chars(_), do: @default_max_chars

  defp html_content?(content_type) when is_binary(content_type) do
    String.starts_with?(content_type, "text/html") or
      String.starts_with?(content_type, "application/xhtml+xml")
  end

  defp html_content?(_), do: false

  defp yaml_escape(nil), do: "\"\""

  defp yaml_escape(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end
end

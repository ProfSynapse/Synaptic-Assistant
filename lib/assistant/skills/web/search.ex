defmodule Assistant.Skills.Web.Search do
  @moduledoc """
  Skill handler for cited web search via OpenRouter or OpenAI.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Accounts
  alias Assistant.Config.Loader, as: ConfigLoader
  alias Assistant.Integrations.OpenAI
  alias Assistant.Integrations.OpenRouter
  alias Assistant.Skills.Helpers, as: SkillsHelpers
  alias Assistant.Skills.Result

  @default_limit 5
  @max_limit 10
  @default_openai_model "gpt-5.2"
  @default_openrouter_model "openai/gpt-5.2"

  @impl true
  def execute(flags, context) do
    query = Map.get(flags, "query") || Map.get(flags, "q")
    provider = normalize_provider(Map.get(flags, "provider"))

    limit =
      SkillsHelpers.parse_limit(
        Map.get(flags, "limit") || Map.get(flags, "max_results"),
        @default_limit,
        @max_limit
      )

    model = Map.get(flags, "model")

    with :ok <- validate_query(query),
         {:ok, selected_provider, client, api_key, resolved_model} <-
           resolve_provider(provider, context, model),
         {:ok, response} <-
           client.web_search(query,
             api_key: api_key,
             model: resolved_model,
             max_results: limit,
             search_context_size: Map.get(flags, "search_context_size"),
             engine: Map.get(flags, "engine")
           ),
         :ok <- ensure_citations(response) do
      {:ok,
       %Result{
         status: :ok,
         content: format_search_result(response),
         metadata: %{
           provider: Atom.to_string(selected_provider),
           model: response.model,
           citations: response.citations
         }
       }}
    else
      {:error, reason} when is_binary(reason) ->
        {:ok, %Result{status: :error, content: reason}}

      {:error, {:rate_limited, retry_after}} ->
        {:ok,
         %Result{
           status: :error,
           content: "Web search was rate-limited. Retry in about #{retry_after} seconds."
         }}

      {:error, {:insufficient_credits, message}} ->
        {:ok,
         %Result{
           status: :error,
           content:
             "The web search provider does not have enough credits for this request#{format_error_suffix(message)}."
         }}

      {:error, {:oauth_only_openai, _}} ->
        {:ok,
         %Result{
           status: :error,
           content:
             "Direct OpenAI web search uses the Responses API and currently requires an OpenAI API key. Your OpenAI connection is OAuth/Codex-only."
         }}

      {:error, :no_provider_available} ->
        {:ok,
         %Result{
           status: :error,
           content:
             "No web search provider is configured. Connect OpenRouter or configure an OpenAI API key."
         }}

      {:error, {:api_error, status, message}} ->
        {:ok,
         %Result{
           status: :error,
           content:
             "The web search provider returned HTTP #{status}#{format_error_suffix(message)}."
         }}

      {:error, {:connection_error, reason}} ->
        {:ok,
         %Result{
           status: :error,
           content: "The web search provider connection failed: #{inspect(reason)}"
         }}

      {:error, reason} ->
        {:ok, %Result{status: :error, content: "Web search failed: #{inspect(reason)}"}}
    end
  end

  defp validate_query(query) when is_binary(query) do
    if String.trim(query) == "" do
      {:error, "Missing required parameter: --query."}
    else
      :ok
    end
  end

  defp validate_query(_), do: {:error, "Missing required parameter: --query."}

  defp resolve_provider(provider, context, requested_model) do
    integrations = context.integrations || %{}
    openrouter = integration(integrations, :openrouter, OpenRouter)
    openai = integration(integrations, :openai, OpenAI)

    openrouter_key = Accounts.openrouter_key_for_user(context.user_id)
    system_openrouter_key = Application.get_env(:assistant, :openrouter_api_key)
    openrouter_available? = present?(openrouter_key) or present?(system_openrouter_key)

    openai_creds = Accounts.openai_credentials_for_user(context.user_id)
    system_openai_key = Application.get_env(:assistant, :openai_api_key)

    openai_api_key =
      cond do
        is_map(openai_creds) and openai_creds[:auth_type] == "api_key" and
            present?(openai_creds[:access_token]) ->
          openai_creds[:access_token]

        present?(system_openai_key) ->
          system_openai_key

        true ->
          nil
      end

    oauth_only? =
      is_map(openai_creds) and openai_creds[:auth_type] == "oauth" and
        not present?(system_openai_key)

    case provider do
      :openrouter ->
        if openrouter_available? do
          {:ok, :openrouter, openrouter, openrouter_key, openrouter_model(requested_model)}
        else
          {:error, :no_provider_available}
        end

      :openai ->
        cond do
          present?(openai_api_key) ->
            {:ok, :openai, openai, openai_api_key, openai_model(requested_model)}

          oauth_only? ->
            {:error, {:oauth_only_openai, context.user_id}}

          true ->
            {:error, :no_provider_available}
        end

      _auto ->
        cond do
          openrouter_available? ->
            {:ok, :openrouter, openrouter, openrouter_key, openrouter_model(requested_model)}

          present?(openai_api_key) ->
            {:ok, :openai, openai, openai_api_key, openai_model(requested_model)}

          oauth_only? ->
            {:error, {:oauth_only_openai, context.user_id}}

          true ->
            {:error, :no_provider_available}
        end
    end
  end

  defp ensure_citations(%{citations: citations}) when is_list(citations) and citations != [],
    do: :ok

  defp ensure_citations(_), do: {:error, "The search provider returned no citations."}

  defp format_search_result(response) do
    answer = response.content || "No answer text returned."

    citations =
      response.citations
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {citation, idx} ->
        title = citation[:title] || citation[:url] || "Untitled source"
        "[#{idx}] #{title}\n#{citation[:url]}"
      end)

    """
    #{answer}

    Citations:
    #{citations}
    """
    |> String.trim()
  end

  defp normalize_provider("openrouter"), do: :openrouter
  defp normalize_provider("openai"), do: :openai
  defp normalize_provider(_), do: :auto

  defp openrouter_model(model) when is_binary(model) and model != "", do: model

  defp openrouter_model(_model) do
    case ConfigLoader.model_for(:orchestrator) do
      %{id: id} when is_binary(id) and id != "" -> id
      _ -> @default_openrouter_model
    end
  end

  defp openai_model("openai/" <> model), do: model
  defp openai_model(model) when is_binary(model) and model != "", do: model

  defp openai_model(_model) do
    case ConfigLoader.model_for(:orchestrator) do
      %{id: "openai/" <> id} -> id
      %{id: id} when is_binary(id) and id != "" -> String.replace_prefix(id, "openai/", "")
      _ -> @default_openai_model
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp format_error_suffix(message) when is_binary(message) do
    trimmed = String.trim(message)

    if trimmed == "" do
      ""
    else
      ": #{trimmed}"
    end
  end

  defp format_error_suffix(_), do: ""

  defp integration(integrations, key, default) when is_list(integrations) do
    Keyword.get(integrations, key, default)
  end

  defp integration(integrations, key, default) when is_map(integrations) do
    Map.get(integrations, key, default)
  end

  defp integration(_, _key, default), do: default
end

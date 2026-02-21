defmodule Assistant.Integrations.LLMRouter do
  @moduledoc """
  Routes LLM calls to OpenAI or OpenRouter based on model/provider and
  per-user connected keys.
  """

  alias Assistant.Accounts
  alias Assistant.Integrations.{OpenAI, OpenRouter}

  @type route :: %{
          client: module(),
          provider: :openai | :openrouter,
          model: String.t() | nil,
          api_key: String.t() | nil,
          openai_auth: map() | nil
        }

  @spec route(String.t() | nil, String.t() | nil) :: route()
  def route(model, user_id) do
    openai_auth = resolve_openai_auth(user_id)
    openai_key = openai_auth && Map.get(openai_auth, :access_token)
    openrouter_key = resolve_openrouter_key(user_id)

    cond do
      openai_model?(model) and is_binary(openai_key) and openai_key != "" ->
        %{
          client: OpenAI,
          provider: :openai,
          model: strip_openai_prefix(model),
          api_key: openai_key,
          openai_auth: openai_auth
        }

      true ->
        %{
          client: OpenRouter,
          provider: :openrouter,
          model: model,
          api_key: openrouter_key,
          openai_auth: nil
        }
    end
  end

  @spec chat_completion([map()], keyword(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def chat_completion(messages, opts, user_id) when is_list(opts) do
    model = Keyword.get(opts, :model)
    routing = route(model, user_id)

    routed_opts =
      opts
      |> maybe_put_model(routing.model)
      |> Keyword.put(:api_key, routing.api_key)
      |> Keyword.put(:openai_auth, routing.openai_auth)
      |> Keyword.put(:user_id, user_id)

    routing.client.chat_completion(messages, routed_opts)
  end

  @spec image_generation(String.t(), keyword(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def image_generation(prompt, opts, user_id) when is_binary(prompt) and is_list(opts) do
    model = Keyword.get(opts, :model)
    routing = route(model, user_id)

    case routing.client do
      OpenRouter ->
        routed_opts =
          opts
          |> maybe_put_model(routing.model)
          |> Keyword.put(:api_key, routing.api_key)

        OpenRouter.image_generation(prompt, routed_opts)

      OpenAI ->
        {:error,
         "OpenAI image generation via direct API is not wired yet for this flow. Choose an OpenRouter-connected image model or connect OpenRouter."}
    end
  end

  @spec openai_model?(String.t() | nil) :: boolean()
  def openai_model?(model) when is_binary(model), do: String.starts_with?(model, "openai/")
  def openai_model?(_), do: false

  @spec strip_openai_prefix(String.t() | nil) :: String.t() | nil
  def strip_openai_prefix(model) when is_binary(model),
    do: String.replace_prefix(model, "openai/", "")

  def strip_openai_prefix(model), do: model

  defp resolve_openrouter_key(user_id) when is_binary(user_id),
    do: Accounts.openrouter_key_for_user(user_id)

  defp resolve_openrouter_key(_), do: nil

  defp resolve_openai_auth(user_id) when is_binary(user_id),
    do: Accounts.openai_credentials_for_user(user_id)

  defp resolve_openai_auth(_), do: nil

  defp maybe_put_model(opts, nil), do: opts
  defp maybe_put_model(opts, model), do: Keyword.put(opts, :model, model)
end

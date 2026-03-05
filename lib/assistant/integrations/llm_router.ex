defmodule Assistant.Integrations.LLMRouter do
  @moduledoc """
  Routes LLM calls to OpenAI or OpenRouter based on the user's connected
  providers — NOT based on model name format.

  ## Routing Priority

  OpenRouter is the default/primary provider. Direct OpenAI is an alternative
  for users who connected ChatGPT via OAuth but haven't connected OpenRouter.

    1. **User has OpenRouter key** (per-user) → OpenRouter. Model IDs sent as-is.
    2. **No per-user OpenRouter key, user has OpenAI credentials** → Direct OpenAI.
       The `openai/` provider prefix is stripped if present (OpenAI expects bare
       model names like `gpt-5-mini`, not `openai/gpt-5-mini`).
    3. **Neither per-user key** → OpenRouter with the system key (the OpenRouter
       client falls back to the system key when no per-user key is provided).

  ## Why Settings-Driven

  Model IDs like `openai/gpt-5-mini` are OpenRouter's naming convention
  (`provider/model`), NOT a routing directive. All config.yaml models use
  OpenRouter format. Routing is determined by which providers the user has
  connected, not by string parsing.
  """

  @behaviour Assistant.Behaviours.LLMRouter

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
    has_openrouter_user = is_binary(openrouter_key) and openrouter_key != ""
    has_openrouter_system = has_system_openrouter_key?()
    has_openai = is_binary(openai_key) and openai_key != ""

    cond do
      # Priority 1: Any OpenRouter key available (per-user or system) — use OpenRouter
      has_openrouter_user or has_openrouter_system ->
        %{
          client: OpenRouter,
          provider: :openrouter,
          model: model,
          api_key: openrouter_key,
          openai_auth: nil
        }

      # Priority 2: No OpenRouter key at all, but user has OpenAI creds — direct OpenAI
      has_openai ->
        %{
          client: OpenAI,
          provider: :openai,
          model: normalize_model_for_openai(model),
          api_key: openai_key,
          openai_auth: openai_auth
        }

      # No credentials available
      true ->
        %{
          client: OpenRouter,
          provider: :openrouter,
          model: model,
          api_key: nil,
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

  @doc """
  Strips the `openai/` provider prefix from a model ID for direct OpenAI API use.

  When routing to OpenAI directly (not via OpenRouter), model IDs need to be
  in bare format (`gpt-5-mini`), not OpenRouter format (`openai/gpt-5-mini`).
  Non-OpenAI prefixed models and bare names pass through unchanged.

  ## Examples

      iex> LLMRouter.normalize_model_for_openai("openai/gpt-5-mini")
      "gpt-5-mini"

      iex> LLMRouter.normalize_model_for_openai("gpt-5-mini")
      "gpt-5-mini"

      iex> LLMRouter.normalize_model_for_openai(nil)
      nil
  """
  @spec normalize_model_for_openai(String.t() | nil) :: String.t() | nil
  def normalize_model_for_openai(model) when is_binary(model),
    do: String.replace_prefix(model, "openai/", "")

  def normalize_model_for_openai(model), do: model

  defp resolve_openrouter_key(user_id) when is_binary(user_id),
    do: Accounts.openrouter_key_for_user(user_id)

  defp resolve_openrouter_key(_), do: nil

  defp resolve_openai_auth(user_id) when is_binary(user_id),
    do: Accounts.openai_credentials_for_user(user_id)

  defp resolve_openai_auth(_), do: nil

  defp maybe_put_model(opts, nil), do: opts
  defp maybe_put_model(opts, model), do: Keyword.put(opts, :model, model)
end

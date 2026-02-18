# lib/assistant/orchestrator/llm_helpers.ex — Shared LLM interaction helpers.
#
# Utility functions used across the orchestrator LLM loop, sub-agents, and
# memory agent. Consolidates duplicated response parsing, model resolution,
# and tool call extraction logic.
#
# Related files:
#   - lib/assistant/orchestrator/loop_runner.ex (orchestrator LLM loop)
#   - lib/assistant/orchestrator/sub_agent.ex (sub-agent LLM loop)
#   - lib/assistant/memory/agent.ex (memory agent LLM loop)
#   - lib/assistant/config/loader.ex (model config)

defmodule Assistant.Orchestrator.LLMHelpers do
  @moduledoc """
  Shared helpers for LLM interactions across orchestrator, sub-agents,
  and memory agent.

  Consolidates:
  - Model resolution from config
  - LLM response parsing (text vs tool calls)
  - Tool call name/args extraction
  """

  alias Assistant.Config.Loader, as: ConfigLoader

  # --- Model Resolution ---

  @doc """
  Resolves the model ID for a given config role.

  Looks up the model config via `Config.Loader.model_for/1` and extracts
  the `:id` field. Returns `nil` if no model is configured for the role.

  ## Parameters

    * `role` - Config role atom (`:orchestrator`, `:sub_agent`, etc.)

  ## Returns

    * A model ID string, or `nil`
  """
  @spec resolve_model(atom()) :: String.t() | nil
  def resolve_model(role) do
    case ConfigLoader.model_for(role) do
      %{id: id} -> id
      nil -> nil
    end
  end

  @doc """
  Builds LLM keyword opts with tools and an optional model.

  If `model` is nil, the `:model` key is omitted from the opts.

  ## Parameters

    * `tools` - List of tool definitions
    * `model` - Model ID string or nil

  ## Returns

    A keyword list suitable for passing to `LLMClient.chat_completion/2`.
  """
  @spec build_llm_opts(list(), String.t() | nil) :: keyword()
  def build_llm_opts(tools, model) do
    opts = [tools: tools]
    if model, do: Keyword.put(opts, :model, model), else: opts
  end

  # --- Response Parsing ---

  @doc """
  Returns true if the LLM response contains text content and no tool calls.
  """
  @spec text_response?(map()) :: boolean()
  def text_response?(response) do
    content = response[:content]
    tool_calls = response[:tool_calls]

    content != nil and content != "" and
      (tool_calls == nil or tool_calls == [])
  end

  @doc """
  Returns true if the LLM response contains tool calls.
  """
  @spec tool_call_response?(map()) :: boolean()
  def tool_call_response?(response) do
    is_list(response[:tool_calls]) and response[:tool_calls] != []
  end

  # --- Tool Call Extraction ---

  @doc """
  Extracts the function name from a tool call map.

  Handles both atom-keyed and string-keyed structures.
  Returns `"unknown"` if the name cannot be extracted.
  """
  @spec extract_function_name(map()) :: String.t()
  def extract_function_name(%{function: %{name: name}}), do: name
  def extract_function_name(%{"function" => %{"name" => name}}), do: name
  def extract_function_name(_), do: "unknown"

  @doc """
  Extracts and decodes function arguments from a tool call map.

  Handles both atom-keyed and string-keyed structures, and both
  pre-decoded maps and JSON strings. Returns `%{}` on failure.
  """
  @spec extract_function_args(map()) :: map()
  def extract_function_args(%{function: %{arguments: args}}) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{}
    end
  end

  def extract_function_args(%{function: %{arguments: args}}) when is_map(args), do: args

  def extract_function_args(%{"function" => %{"arguments" => args}}) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{}
    end
  end

  def extract_function_args(%{"function" => %{"arguments" => args}}) when is_map(args), do: args
  def extract_function_args(_), do: %{}

  # --- Result Text Extraction ---

  @doc """
  Extracts the last assistant text content from a message list.

  Walks backwards through messages and returns the first non-empty
  assistant content string, or `nil` if none found.
  """
  @spec extract_last_assistant_text([map()]) :: String.t() | nil
  def extract_last_assistant_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{role: "assistant", content: content} when is_binary(content) and content != "" ->
        content

      _ ->
        nil
    end)
  end
end

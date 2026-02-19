# lib/assistant/orchestrator/nudger.ex — Centralized error→recommendation prompt system.
#
# Maps error atoms to short, actionable recovery hints loaded from
# config/prompts/nudges.yaml via PromptLoader's ETS. Adding a new nudge
# requires zero code changes — just add a key to the YAML file.
#
# The Nudger is a plain module (not a GenServer). It reads compiled EEx
# templates from PromptLoader's ETS at call time, renders them with
# optional detail variables, and returns the hint string.
#
# Related files:
#   - config/prompts/nudges.yaml (source of truth for nudge templates)
#   - lib/assistant/config/prompt_loader.ex (ETS loader)
#   - lib/assistant/orchestrator/engine.ex (consumer — appends hints to errors)

defmodule Assistant.Orchestrator.Nudger do
  @moduledoc """
  Centralized error recovery hint system.

  Maps error atoms (e.g., `:context_budget_exceeded`) to short actionable
  recommendation strings loaded from `config/prompts/nudges.yaml`. Hints
  are rendered as EEx templates with optional detail variables for
  dynamic content like token counts.

  ## Extensibility

  Adding a new nudge requires **zero code changes** — add a section key
  to `config/prompts/nudges.yaml` and it's available immediately (or
  after `PromptLoader.reload/0` if hot-reloading).

  ## Usage

      # Simple lookup
      Nudger.lookup(:skill_not_found)
      # => "Skill not found in registry. Use get_skill to browse..."

      # With interpolation
      Nudger.lookup(:context_budget_exceeded, %{overage_tokens: 1200})
      # => "Context exceeds the model's window by ~1200 tokens..."

      # Unknown error — graceful nil
      Nudger.lookup(:unknown_error)
      # => nil

  ## Integration

  Engine and LoopRunner call `format_error/2` or `format_error/3` to
  produce error text with an appended hint when available:

      Nudger.format_error("Dispatch failed", :circuit_breaker_open)
      # => "Dispatch failed\\n\\nHint: The circuit breaker for this..."
  """

  alias Assistant.Config.PromptLoader

  @doc """
  Looks up a nudge hint for the given error atom.

  Returns the rendered hint string, or `nil` if no nudge is configured
  for this error type or if nudges.yaml is not loaded.

  ## Parameters

    * `error_type` - Error atom (e.g., `:context_budget_exceeded`)

  ## Returns

    * `String.t()` — Rendered hint text
    * `nil` — No nudge configured for this error type
  """
  @spec lookup(atom()) :: String.t() | nil
  def lookup(error_type) when is_atom(error_type) do
    lookup(error_type, %{})
  end

  @doc """
  Looks up a nudge hint with interpolation variables.

  Detail variables are passed to the EEx template as assigns
  (e.g., `%{overage_tokens: 1200}` renders `<%= @overage_tokens %>`).

  ## Parameters

    * `error_type` - Error atom (e.g., `:context_budget_exceeded`)
    * `details` - Map of variables for EEx interpolation

  ## Returns

    * `String.t()` — Rendered hint text
    * `nil` — No nudge configured, or rendering failed
  """
  @spec lookup(atom(), map()) :: String.t() | nil
  def lookup(error_type, details) when is_atom(error_type) and is_map(details) do
    case PromptLoader.render_section(:nudges, error_type, details) do
      {:ok, rendered} -> String.trim(rendered)
      {:error, _} -> nil
    end
  end

  @doc """
  Extracts the error type atom from a structured error term.

  Handles common error tuple patterns used throughout the codebase:

    * `{:error, :atom}` → `:atom`
    * `{:error, {:atom, _details}}` → `:atom`
    * `:atom` → `:atom`
    * Other → `nil`

  ## Examples

      extract_error_type({:error, :no_model_specified})
      # => :no_model_specified

      extract_error_type({:error, {:rate_limited, 60}})
      # => :rate_limited

      extract_error_type("string error")
      # => nil
  """
  @spec extract_error_type(term()) :: atom() | nil
  def extract_error_type({:error, {type, _details}}) when is_atom(type), do: type
  def extract_error_type({:error, type}) when is_atom(type), do: type
  def extract_error_type(type) when is_atom(type), do: type
  def extract_error_type(_), do: nil

  @doc """
  Extracts detail data from a structured error term for interpolation.

  Returns a map suitable for passing to `lookup/2`:

    * `{:error, {:atom, %{key: val}}}` → `%{key: val}`
    * `{:error, {:atom, detail}}` → `%{detail: detail}`
    * Other → `%{}`
  """
  @spec extract_error_details(term()) :: map()
  def extract_error_details({:error, {_type, details}}) when is_map(details), do: details
  def extract_error_details({:error, {_type, detail}}), do: %{detail: detail}
  def extract_error_details(_), do: %{}

  @doc """
  Formats an error message with an appended nudge hint if available.

  This is the primary integration point for engine.ex. It takes a base
  error message string and an error term, extracts the error type,
  looks up a nudge, and appends it.

  ## Parameters

    * `base_message` - The original error text
    * `error` - The structured error term (for type extraction)

  ## Returns

  The base message with hint appended, or just the base message if
  no nudge is available.

  ## Examples

      format_error("Dispatch failed", {:error, :circuit_breaker_open})
      # => "Dispatch failed\\n\\nHint: The circuit breaker for this..."

      format_error("Unknown error", {:error, :something_unknown})
      # => "Unknown error"
  """
  @spec format_error(String.t(), term()) :: String.t()
  def format_error(base_message, error) do
    error_type = extract_error_type(error)
    details = extract_error_details(error)
    format_error(base_message, error_type, details)
  end

  @doc """
  Formats an error message with a nudge hint for a specific error type and details.

  ## Parameters

    * `base_message` - The original error text
    * `error_type` - Error atom (or nil)
    * `details` - Map of interpolation variables

  ## Returns

  The base message with hint appended, or just the base message if
  no nudge is available.
  """
  @spec format_error(String.t(), atom() | nil, map()) :: String.t()
  def format_error(base_message, nil, _details), do: base_message

  def format_error(base_message, error_type, details) when is_atom(error_type) do
    case lookup(error_type, details) do
      nil -> base_message
      hint -> "#{base_message}\n\nHint: #{hint}"
    end
  end
end

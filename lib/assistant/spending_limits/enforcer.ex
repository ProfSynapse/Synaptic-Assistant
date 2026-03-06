# lib/assistant/spending_limits/enforcer.ex — Pre-flight spending check for LLM pipeline.
#
# Bridges the chat user_id to settings_user_id and delegates to SpendingLimits.check_budget/1.
# Wired into LLMRouter.chat_completion/3 at the top of the function.
#
# Related files:
#   - lib/assistant/spending_limits.ex (context module)
#   - lib/assistant/integrations/llm_router.ex (insertion point)

defmodule Assistant.SpendingLimits.Enforcer do
  @moduledoc false

  alias Assistant.{Accounts, SpendingLimits}

  @over_budget_user_message "Your usage limit has been reached for this billing period."

  @doc "Consistent user-facing message for over-budget conditions."
  @spec over_budget_message() :: String.t()
  def over_budget_message, do: @over_budget_user_message

  @spec check_budget(String.t() | nil) :: :ok | {:warning, float()} | {:error, :over_budget}
  def check_budget(nil), do: :ok
  def check_budget("unknown"), do: :ok

  def check_budget(user_id) do
    case Accounts.get_settings_user_by_user_id(user_id) do
      nil -> :ok
      %{is_admin: true} -> :ok
      settings_user -> SpendingLimits.check_budget(settings_user.id)
    end
  end

  @doc """
  Records LLM usage for a chat user. Bridges to settings_user_id.
  No-op if user has no spending limit configured.
  """
  @spec record_usage(String.t() | nil, map()) :: :ok
  def record_usage(nil, _usage_data), do: :ok
  def record_usage("unknown", _usage_data), do: :ok

  def record_usage(user_id, usage_data) do
    case Accounts.get_settings_user_by_user_id(user_id) do
      nil -> :ok
      settings_user -> SpendingLimits.record_usage(settings_user.id, usage_data)
    end

    :ok
  end

  @doc """
  Extracts usage from an LLM response and records spending for the user.

  Accepts a state map with `:user_id` and an LLM response map. Extracts
  `:cost`, `:prompt_tokens`, and `:completion_tokens` from `response[:usage]`
  and delegates to `record_usage/2`.

  Used by LoopRunner and SubAgent after successful LLM calls.
  """
  @spec record_spending(map(), map() | nil) :: :ok
  def record_spending(state, response) do
    usage = if is_map(response), do: response[:usage] || %{}, else: %{}

    record_usage(state[:user_id], %{
      cost: usage[:cost] || 0.0,
      prompt_tokens: usage[:prompt_tokens] || 0,
      completion_tokens: usage[:completion_tokens] || 0
    })
  end
end

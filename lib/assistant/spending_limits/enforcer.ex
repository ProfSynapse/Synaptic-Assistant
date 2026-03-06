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
end

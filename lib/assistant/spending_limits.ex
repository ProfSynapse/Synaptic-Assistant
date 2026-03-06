# lib/assistant/spending_limits.ex — Context module for spending limits and usage tracking.
#
# Provides budget checking (pre-flight) and usage recording (post-flight) for
# the LLM pipeline. Spending limits are configured per settings_user by admins.
# Usage records are upserting per-period aggregates.
#
# Related files:
#   - lib/assistant/schemas/spending_limit.ex (schema)
#   - lib/assistant/schemas/usage_record.ex (schema)
#   - lib/assistant/spending_limits/enforcer.ex (bridges chat user_id → settings_user_id)
#   - lib/assistant/integrations/llm_router.ex (pre-flight check insertion point)
#   - lib/assistant/orchestrator/loop_runner.ex (post-flight recording)
#   - lib/assistant/orchestrator/sub_agent.ex (post-flight recording)

defmodule Assistant.SpendingLimits do
  @moduledoc """
  Context module for spending limits and usage tracking.

  Spending limits are admin-managed per settings_user. Usage records aggregate
  LLM call costs per billing period (monthly). Budget checks are pre-flight
  (before LLM calls) and usage recording is post-flight (after LLM calls).
  """

  import Ecto.Query, warn: false
  alias Assistant.Repo
  alias Assistant.Schemas.{SpendingLimit, UsageRecord}

  require Logger

  # --- Budget Checking (Pre-flight) ---

  @doc """
  Checks the current budget status for a settings_user.

  Returns:
    - `:ok` — under budget (or no limit configured)
    - `{:warning, percentage}` — approaching threshold
    - `{:error, :over_budget}` — hard cap exceeded
  """
  @spec check_budget(String.t()) :: :ok | {:warning, float()} | {:error, :over_budget}
  def check_budget(settings_user_id) when is_binary(settings_user_id) do
    case get_spending_limit(settings_user_id) do
      nil ->
        :ok

      %SpendingLimit{} = limit ->
        {period_start, _period_end} = current_period(limit)
        used_cents = current_period_usage_cents(settings_user_id, period_start)
        percentage = if limit.budget_cents > 0, do: used_cents / limit.budget_cents * 100, else: 0.0

        cond do
          limit.hard_cap and used_cents >= limit.budget_cents ->
            {:error, :over_budget}

          percentage >= limit.warning_threshold ->
            {:warning, Float.round(percentage, 1)}

          true ->
            :ok
        end
    end
  end

  def check_budget(_), do: :ok

  # --- Usage Recording (Post-flight) ---

  @doc """
  Records LLM usage for the current billing period. Upserts atomically.

  `usage_data` should include:
    - `:cost` — cost in dollars (float), converted to cents internally
    - `:prompt_tokens` — integer
    - `:completion_tokens` — integer
  """
  @spec record_usage(String.t(), map()) :: :ok | {:error, term()}
  def record_usage(settings_user_id, usage_data) when is_binary(settings_user_id) do
    case get_spending_limit(settings_user_id) do
      nil ->
        :ok

      %SpendingLimit{} = limit ->
        {period_start, period_end} = current_period(limit)
        cost_cents = round((usage_data[:cost] || 0.0) * 100)
        prompt_tokens = usage_data[:prompt_tokens] || 0
        completion_tokens = usage_data[:completion_tokens] || 0

        Repo.insert(
          %UsageRecord{
            settings_user_id: settings_user_id,
            period_start: period_start,
            period_end: period_end,
            total_cost_cents: cost_cents,
            total_prompt_tokens: prompt_tokens,
            total_completion_tokens: completion_tokens,
            call_count: 1
          },
          on_conflict:
            from(u in UsageRecord,
              update: [
                inc: [
                  total_cost_cents: ^cost_cents,
                  total_prompt_tokens: ^prompt_tokens,
                  total_completion_tokens: ^completion_tokens,
                  call_count: 1
                ],
                set: [updated_at: ^DateTime.utc_now()]
              ]
            ),
          conflict_target: [:settings_user_id, :period_start]
        )

        :ok
    end
  rescue
    e ->
      Logger.warning("Failed to record usage",
        settings_user_id: settings_user_id,
        error: inspect(e)
      )

      {:error, e}
  end

  def record_usage(_, _), do: :ok

  # --- Query Helpers (for admin UI) ---

  @doc """
  Returns current usage summary for a settings_user.
  """
  @spec current_usage(String.t()) :: map()
  def current_usage(settings_user_id) when is_binary(settings_user_id) do
    case get_spending_limit(settings_user_id) do
      nil ->
        %{has_limit: false}

      %SpendingLimit{} = limit ->
        {period_start, period_end} = current_period(limit)
        used_cents = current_period_usage_cents(settings_user_id, period_start)
        percentage = if limit.budget_cents > 0, do: used_cents / limit.budget_cents * 100, else: 0.0

        %{
          has_limit: true,
          budget_cents: limit.budget_cents,
          used_cents: used_cents,
          percentage: Float.round(percentage, 1),
          period_start: period_start,
          period_end: period_end,
          hard_cap: limit.hard_cap,
          warning_threshold: limit.warning_threshold
        }
    end
  end

  def current_usage(_), do: %{has_limit: false}

  @doc """
  Gets the spending limit for a settings_user, or nil if none configured.
  """
  @spec get_spending_limit(String.t()) :: SpendingLimit.t() | nil
  def get_spending_limit(settings_user_id) when is_binary(settings_user_id) do
    Repo.get_by(SpendingLimit, settings_user_id: settings_user_id)
  end

  def get_spending_limit(_), do: nil

  @doc """
  Creates or updates a spending limit for a settings_user.
  """
  @spec upsert_spending_limit(String.t(), map()) :: {:ok, SpendingLimit.t()} | {:error, Ecto.Changeset.t()}
  def upsert_spending_limit(settings_user_id, attrs) when is_binary(settings_user_id) do
    case get_spending_limit(settings_user_id) do
      nil ->
        %SpendingLimit{settings_user_id: settings_user_id}
        |> SpendingLimit.changeset(attrs)
        |> Repo.insert()

      %SpendingLimit{} = existing ->
        existing
        |> SpendingLimit.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Deletes the spending limit for a settings_user.
  """
  @spec delete_spending_limit(String.t()) :: :ok
  def delete_spending_limit(settings_user_id) when is_binary(settings_user_id) do
    from(sl in SpendingLimit, where: sl.settings_user_id == ^settings_user_id)
    |> Repo.delete_all()

    :ok
  end

  # --- Period Calculation ---

  defp current_period(%SpendingLimit{period: "monthly", reset_day: reset_day}) do
    today = Date.utc_today()
    period_start = period_start_date(today, reset_day)
    period_end = period_end_date(period_start, reset_day)
    {period_start, period_end}
  end

  defp period_start_date(today, reset_day) do
    clamped_day = min(reset_day, Date.days_in_month(today))

    if today.day >= clamped_day do
      Date.new!(today.year, today.month, clamped_day)
    else
      prev = Date.add(today, -today.day)
      clamped_prev = min(reset_day, Date.days_in_month(prev))
      Date.new!(prev.year, prev.month, clamped_prev)
    end
  end

  defp period_end_date(period_start, reset_day) do
    next_month = Date.add(period_start, Date.days_in_month(period_start))
    clamped_day = min(reset_day, Date.days_in_month(next_month))
    next_period_start = Date.new!(next_month.year, next_month.month, clamped_day)
    Date.add(next_period_start, -1)
  end

  defp current_period_usage_cents(settings_user_id, period_start) do
    Repo.one(
      from(u in UsageRecord,
        where: u.settings_user_id == ^settings_user_id and u.period_start == ^period_start,
        select: coalesce(u.total_cost_cents, 0)
      )
    ) || 0
  end
end

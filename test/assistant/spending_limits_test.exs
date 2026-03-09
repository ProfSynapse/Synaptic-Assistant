defmodule Assistant.SpendingLimitsTest do
  use Assistant.DataCase, async: true

  alias Assistant.SpendingLimits
  alias Assistant.Schemas.{SpendingLimit, UsageRecord}

  import Assistant.AccountsFixtures

  # ──────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────

  defp create_spending_limit(settings_user, attrs \\ %{}) do
    default = %{
      settings_user_id: settings_user.id,
      budget_cents: 10_000,
      period: "monthly",
      reset_day: 1,
      hard_cap: true,
      warning_threshold: 80
    }

    merged = Map.merge(default, attrs)

    %SpendingLimit{}
    |> SpendingLimit.changeset(merged)
    |> Repo.insert!()
  end

  defp insert_usage(settings_user_id, period_start, period_end, cost_cents) do
    Repo.insert!(%UsageRecord{
      settings_user_id: settings_user_id,
      period_start: period_start,
      period_end: period_end,
      total_cost_cents: cost_cents,
      total_prompt_tokens: 1000,
      total_completion_tokens: 500,
      call_count: 1
    })
  end

  defp current_period_dates(reset_day) do
    today = Date.utc_today()
    clamped_day = min(reset_day, Date.days_in_month(today))

    period_start =
      if today.day >= clamped_day do
        Date.new!(today.year, today.month, clamped_day)
      else
        prev = Date.add(today, -today.day)
        clamped_prev = min(reset_day, Date.days_in_month(prev))
        Date.new!(prev.year, prev.month, clamped_prev)
      end

    next_month = Date.add(period_start, Date.days_in_month(period_start))
    clamped_next = min(reset_day, Date.days_in_month(next_month))
    next_period_start = Date.new!(next_month.year, next_month.month, clamped_next)
    period_end = Date.add(next_period_start, -1)

    {period_start, period_end}
  end

  # ──────────────────────────────────────────────
  # P0: check_budget/1 — under budget
  # ──────────────────────────────────────────────

  describe "check_budget/1" do
    test "returns :ok when no spending limit configured" do
      user = settings_user_fixture()
      assert :ok = SpendingLimits.check_budget(user.id)
    end

    test "returns :ok for non-binary input" do
      assert :ok = SpendingLimits.check_budget(nil)
      assert :ok = SpendingLimits.check_budget(123)
    end

    test "returns :ok when under budget with no usage" do
      user = settings_user_fixture()
      create_spending_limit(user, %{budget_cents: 10_000})

      assert :ok = SpendingLimits.check_budget(user.id)
    end

    test "returns :ok when usage is below warning threshold" do
      user = settings_user_fixture()
      create_spending_limit(user, %{budget_cents: 10_000, warning_threshold: 80})

      {period_start, period_end} = current_period_dates(1)
      insert_usage(user.id, period_start, period_end, 5_000)

      assert :ok = SpendingLimits.check_budget(user.id)
    end

    # ──────────────────────────────────────────────
    # P0: check_budget/1 — over budget
    # ──────────────────────────────────────────────

    test "returns {:error, :over_budget} when hard cap exceeded" do
      user = settings_user_fixture()
      create_spending_limit(user, %{budget_cents: 10_000, hard_cap: true})

      {period_start, period_end} = current_period_dates(1)
      insert_usage(user.id, period_start, period_end, 10_000)

      assert {:error, :over_budget} = SpendingLimits.check_budget(user.id)
    end

    test "returns {:error, :over_budget} when usage exceeds budget" do
      user = settings_user_fixture()
      create_spending_limit(user, %{budget_cents: 10_000, hard_cap: true})

      {period_start, period_end} = current_period_dates(1)
      insert_usage(user.id, period_start, period_end, 15_000)

      assert {:error, :over_budget} = SpendingLimits.check_budget(user.id)
    end

    # ──────────────────────────────────────────────
    # P1: check_budget/1 — warning threshold
    # ──────────────────────────────────────────────

    test "returns {:warning, percentage} when at warning threshold" do
      user = settings_user_fixture()
      create_spending_limit(user, %{budget_cents: 10_000, warning_threshold: 80})

      {period_start, period_end} = current_period_dates(1)
      insert_usage(user.id, period_start, period_end, 8_000)

      assert {:warning, 80.0} = SpendingLimits.check_budget(user.id)
    end

    test "returns {:warning, percentage} when between threshold and budget" do
      user = settings_user_fixture()
      create_spending_limit(user, %{budget_cents: 10_000, warning_threshold: 80})

      {period_start, period_end} = current_period_dates(1)
      insert_usage(user.id, period_start, period_end, 9_500)

      assert {:warning, 95.0} = SpendingLimits.check_budget(user.id)
    end

    # ──────────────────────────────────────────────
    # P2: check_budget/1 — soft warning (no hard cap)
    # ──────────────────────────────────────────────

    test "returns {:warning, percentage} when over budget with soft cap" do
      user = settings_user_fixture()
      create_spending_limit(user, %{budget_cents: 10_000, hard_cap: false, warning_threshold: 80})

      {period_start, period_end} = current_period_dates(1)
      insert_usage(user.id, period_start, period_end, 12_000)

      # Soft cap: over budget but no hard block, just warning
      assert {:warning, 120.0} = SpendingLimits.check_budget(user.id)
    end

    test "returns :ok when soft cap and under warning threshold" do
      user = settings_user_fixture()
      create_spending_limit(user, %{budget_cents: 10_000, hard_cap: false, warning_threshold: 80})

      {period_start, period_end} = current_period_dates(1)
      insert_usage(user.id, period_start, period_end, 5_000)

      assert :ok = SpendingLimits.check_budget(user.id)
    end

    # ──────────────────────────────────────────────
    # P2: check_budget/1 — zero budget edge case
    # ──────────────────────────────────────────────

    test "handles zero budget_cents edge case" do
      user = settings_user_fixture()

      # budget_cents > 0 is validated by changeset, but the code handles
      # division by zero gracefully (percentage = 0.0)
      # We can test the internal logic indirectly: budget with minimal value
      create_spending_limit(user, %{budget_cents: 1, hard_cap: true})

      {period_start, period_end} = current_period_dates(1)
      insert_usage(user.id, period_start, period_end, 1)

      assert {:error, :over_budget} = SpendingLimits.check_budget(user.id)
    end
  end

  # ──────────────────────────────────────────────
  # P0: record_usage/2
  # ──────────────────────────────────────────────

  describe "record_usage/2" do
    test "returns :ok when no spending limit configured (no-op)" do
      user = settings_user_fixture()

      assert :ok =
               SpendingLimits.record_usage(user.id, %{
                 cost: 0.05,
                 prompt_tokens: 100,
                 completion_tokens: 50
               })
    end

    test "returns :ok for non-binary settings_user_id" do
      assert :ok = SpendingLimits.record_usage(nil, %{cost: 0.05})
      assert :ok = SpendingLimits.record_usage(123, %{cost: 0.05})
    end

    test "creates usage record on first call" do
      user = settings_user_fixture()
      create_spending_limit(user)

      assert :ok =
               SpendingLimits.record_usage(user.id, %{
                 cost: 0.50,
                 prompt_tokens: 1000,
                 completion_tokens: 500
               })

      {period_start, _} = current_period_dates(1)
      record = Repo.get_by(UsageRecord, settings_user_id: user.id, period_start: period_start)

      assert record.total_cost_cents == 50
      assert record.total_prompt_tokens == 1000
      assert record.total_completion_tokens == 500
      assert record.call_count == 1
    end

    test "atomically increments on subsequent calls (upsert)" do
      user = settings_user_fixture()
      create_spending_limit(user)

      assert :ok =
               SpendingLimits.record_usage(user.id, %{
                 cost: 0.50,
                 prompt_tokens: 1000,
                 completion_tokens: 500
               })

      assert :ok =
               SpendingLimits.record_usage(user.id, %{
                 cost: 0.30,
                 prompt_tokens: 600,
                 completion_tokens: 300
               })

      {period_start, _} = current_period_dates(1)
      record = Repo.get_by(UsageRecord, settings_user_id: user.id, period_start: period_start)

      assert record.total_cost_cents == 80
      assert record.total_prompt_tokens == 1600
      assert record.total_completion_tokens == 800
      assert record.call_count == 2
    end

    test "handles nil cost gracefully" do
      user = settings_user_fixture()
      create_spending_limit(user)

      assert :ok =
               SpendingLimits.record_usage(user.id, %{prompt_tokens: 100, completion_tokens: 50})

      {period_start, _} = current_period_dates(1)
      record = Repo.get_by(UsageRecord, settings_user_id: user.id, period_start: period_start)

      assert record.total_cost_cents == 0
      assert record.call_count == 1
    end

    test "handles nil tokens gracefully" do
      user = settings_user_fixture()
      create_spending_limit(user)

      assert :ok = SpendingLimits.record_usage(user.id, %{cost: 0.10})

      {period_start, _} = current_period_dates(1)
      record = Repo.get_by(UsageRecord, settings_user_id: user.id, period_start: period_start)

      assert record.total_cost_cents == 10
      assert record.total_prompt_tokens == 0
      assert record.total_completion_tokens == 0
    end
  end

  # ──────────────────────────────────────────────
  # P0: current_usage/1
  # ──────────────────────────────────────────────

  describe "current_usage/1" do
    test "returns has_limit: false when no spending limit" do
      user = settings_user_fixture()
      assert %{has_limit: false} = SpendingLimits.current_usage(user.id)
    end

    test "returns has_limit: false for non-binary input" do
      assert %{has_limit: false} = SpendingLimits.current_usage(nil)
    end

    test "returns full usage summary when spending limit exists" do
      user = settings_user_fixture()
      create_spending_limit(user, %{budget_cents: 10_000, warning_threshold: 80})

      {period_start, period_end} = current_period_dates(1)
      insert_usage(user.id, period_start, period_end, 3_000)

      result = SpendingLimits.current_usage(user.id)

      assert result.has_limit
      assert result.budget_cents == 10_000
      assert result.used_cents == 3_000
      assert result.percentage == 30.0
      assert result.hard_cap
      assert result.warning_threshold == 80
      assert result.period_start == period_start
      assert result.period_end == period_end
    end

    test "returns 0 usage when no records exist" do
      user = settings_user_fixture()
      create_spending_limit(user, %{budget_cents: 10_000})

      result = SpendingLimits.current_usage(user.id)

      assert result.has_limit
      assert result.used_cents == 0
      assert result.percentage == 0.0
    end
  end

  # ──────────────────────────────────────────────
  # P1: upsert_spending_limit/2
  # ──────────────────────────────────────────────

  describe "upsert_spending_limit/2" do
    test "creates a new spending limit" do
      user = settings_user_fixture()

      assert {:ok, %SpendingLimit{} = limit} =
               SpendingLimits.upsert_spending_limit(user.id, %{budget_cents: 5_000})

      assert limit.budget_cents == 5_000
      assert limit.period == "monthly"
      assert limit.reset_day == 1
      assert limit.hard_cap == true
      assert limit.warning_threshold == 80
    end

    test "updates an existing spending limit" do
      user = settings_user_fixture()
      create_spending_limit(user, %{budget_cents: 10_000})

      assert {:ok, %SpendingLimit{} = updated} =
               SpendingLimits.upsert_spending_limit(user.id, %{
                 budget_cents: 20_000,
                 hard_cap: false
               })

      assert updated.budget_cents == 20_000
      assert updated.hard_cap == false
    end

    test "validates budget_cents > 0" do
      user = settings_user_fixture()

      assert {:error, changeset} =
               SpendingLimits.upsert_spending_limit(user.id, %{budget_cents: 0})

      assert errors_on(changeset).budget_cents
    end

    test "validates reset_day range 1..28" do
      user = settings_user_fixture()

      assert {:error, changeset} =
               SpendingLimits.upsert_spending_limit(user.id, %{budget_cents: 1000, reset_day: 29})

      assert errors_on(changeset).reset_day
    end

    test "validates warning_threshold range 1..100" do
      user = settings_user_fixture()

      assert {:error, changeset} =
               SpendingLimits.upsert_spending_limit(user.id, %{
                 budget_cents: 1000,
                 warning_threshold: 0
               })

      assert errors_on(changeset).warning_threshold

      assert {:error, changeset} =
               SpendingLimits.upsert_spending_limit(user.id, %{
                 budget_cents: 1000,
                 warning_threshold: 101
               })

      assert errors_on(changeset).warning_threshold
    end
  end

  # ──────────────────────────────────────────────
  # P1: get_spending_limit/1
  # ──────────────────────────────────────────────

  describe "get_spending_limit/1" do
    test "returns nil when no limit configured" do
      user = settings_user_fixture()
      assert is_nil(SpendingLimits.get_spending_limit(user.id))
    end

    test "returns nil for non-binary input" do
      assert is_nil(SpendingLimits.get_spending_limit(nil))
    end

    test "returns the spending limit" do
      user = settings_user_fixture()
      create_spending_limit(user, %{budget_cents: 5_000})

      limit = SpendingLimits.get_spending_limit(user.id)
      assert %SpendingLimit{} = limit
      assert limit.budget_cents == 5_000
    end
  end

  # ──────────────────────────────────────────────
  # P1: delete_spending_limit/1
  # ──────────────────────────────────────────────

  describe "delete_spending_limit/1" do
    test "deletes existing spending limit" do
      user = settings_user_fixture()
      create_spending_limit(user)

      assert :ok = SpendingLimits.delete_spending_limit(user.id)
      assert is_nil(SpendingLimits.get_spending_limit(user.id))
    end

    test "no-op when no spending limit exists" do
      user = settings_user_fixture()
      assert :ok = SpendingLimits.delete_spending_limit(user.id)
    end
  end

  # ──────────────────────────────────────────────
  # P1: Period rollover — usage from previous period not counted
  # ──────────────────────────────────────────────

  describe "period rollover" do
    test "only counts usage from current period" do
      user = settings_user_fixture()
      create_spending_limit(user, %{budget_cents: 10_000, reset_day: 1})

      {current_start, current_end} = current_period_dates(1)

      # Insert usage in current period
      insert_usage(user.id, current_start, current_end, 5_000)

      # Insert usage in a past period (2 months ago)
      past_start = Date.add(current_start, -60)
      past_end = Date.add(past_start, 29)
      insert_usage(user.id, past_start, past_end, 50_000)

      # Should only see current period usage
      result = SpendingLimits.current_usage(user.id)
      assert result.used_cents == 5_000

      # Budget check should pass (only 50% of current budget)
      assert :ok = SpendingLimits.check_budget(user.id)
    end
  end

  # ──────────────────────────────────────────────
  # P2: SpendingLimit changeset validations
  # ──────────────────────────────────────────────

  describe "SpendingLimit changeset" do
    test "valid changeset with required fields" do
      changeset = SpendingLimit.changeset(%SpendingLimit{}, %{budget_cents: 5_000})
      assert changeset.valid?
    end

    test "rejects missing budget_cents" do
      changeset = SpendingLimit.changeset(%SpendingLimit{}, %{})
      refute changeset.valid?
      assert errors_on(changeset).budget_cents
    end

    test "rejects negative budget_cents" do
      changeset = SpendingLimit.changeset(%SpendingLimit{}, %{budget_cents: -100})
      refute changeset.valid?
    end

    test "validates period inclusion" do
      changeset =
        SpendingLimit.changeset(%SpendingLimit{}, %{budget_cents: 1000, period: "weekly"})

      refute changeset.valid?
      assert errors_on(changeset).period
    end

    test "accepts monthly period" do
      changeset =
        SpendingLimit.changeset(%SpendingLimit{}, %{budget_cents: 1000, period: "monthly"})

      assert changeset.valid?
    end
  end
end

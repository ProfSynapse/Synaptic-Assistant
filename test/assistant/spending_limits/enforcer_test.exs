defmodule Assistant.SpendingLimits.EnforcerTest do
  use Assistant.DataCase, async: true

  alias Assistant.SpendingLimits.Enforcer
  alias Assistant.Schemas.{SpendingLimit, UsageRecord}

  import Assistant.AccountsFixtures

  # ──────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────

  defp create_linked_settings_user(attrs \\ %{}) do
    settings_user = settings_user_fixture(attrs)
    user = create_chat_user()

    settings_user
    |> Ecto.Changeset.change(user_id: user.id)
    |> Repo.update!()

    {user, Repo.get!(Assistant.Accounts.SettingsUser, settings_user.id)}
  end

  defp create_chat_user do
    {:ok, user} =
      %Assistant.Schemas.User{}
      |> Assistant.Schemas.User.changeset(%{
        external_id: "test-#{System.unique_integer([:positive])}",
        channel: "test"
      })
      |> Repo.insert()

    user
  end

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

  defp insert_usage(settings_user_id, period_start, period_end, cost_cents) do
    Repo.insert!(%UsageRecord{
      settings_user_id: settings_user_id,
      period_start: period_start,
      period_end: period_end,
      total_cost_cents: cost_cents,
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      call_count: 1
    })
  end

  # ──────────────────────────────────────────────
  # P0: check_budget/1 — nil/unknown
  # ──────────────────────────────────────────────

  describe "check_budget/1 with nil/unknown" do
    test "returns :ok for nil user_id" do
      assert :ok = Enforcer.check_budget(nil)
    end

    test "returns :ok for \"unknown\" user_id" do
      assert :ok = Enforcer.check_budget("unknown")
    end
  end

  # ──────────────────────────────────────────────
  # P0: check_budget/1 — no linked settings_user
  # ──────────────────────────────────────────────

  describe "check_budget/1 with no linked settings_user" do
    test "returns :ok when chat user has no linked settings_user" do
      user = create_chat_user()
      assert :ok = Enforcer.check_budget(user.id)
    end
  end

  # ──────────────────────────────────────────────
  # P0: check_budget/1 — admin bypass
  # ──────────────────────────────────────────────

  describe "check_budget/1 with admin" do
    test "admin bypasses spending check even when over budget" do
      {user, settings_user} = create_linked_settings_user()

      settings_user
      |> Ecto.Changeset.change(is_admin: true)
      |> Repo.update!()

      create_spending_limit(settings_user, %{budget_cents: 100, hard_cap: true})

      {period_start, period_end} = current_period_dates(1)
      insert_usage(settings_user.id, period_start, period_end, 500)

      assert :ok = Enforcer.check_budget(user.id)
    end
  end

  # ──────────────────────────────────────────────
  # P0: check_budget/1 — bridges to SpendingLimits
  # ──────────────────────────────────────────────

  describe "check_budget/1 delegation" do
    test "returns :ok when no spending limit configured" do
      {user, _settings_user} = create_linked_settings_user()
      assert :ok = Enforcer.check_budget(user.id)
    end

    test "returns {:error, :over_budget} when over budget" do
      {user, settings_user} = create_linked_settings_user()
      create_spending_limit(settings_user, %{budget_cents: 1_000, hard_cap: true})

      {period_start, period_end} = current_period_dates(1)
      insert_usage(settings_user.id, period_start, period_end, 1_000)

      assert {:error, :over_budget} = Enforcer.check_budget(user.id)
    end

    test "returns {:warning, percentage} when at warning threshold" do
      {user, settings_user} = create_linked_settings_user()
      create_spending_limit(settings_user, %{budget_cents: 10_000, warning_threshold: 80})

      {period_start, period_end} = current_period_dates(1)
      insert_usage(settings_user.id, period_start, period_end, 9_000)

      assert {:warning, 90.0} = Enforcer.check_budget(user.id)
    end
  end

  # ──────────────────────────────────────────────
  # P0: record_usage/2 — nil/unknown
  # ──────────────────────────────────────────────

  describe "record_usage/2 with nil/unknown" do
    test "returns :ok for nil user_id" do
      assert :ok = Enforcer.record_usage(nil, %{cost: 0.05})
    end

    test "returns :ok for \"unknown\" user_id" do
      assert :ok = Enforcer.record_usage("unknown", %{cost: 0.05})
    end
  end

  # ──────────────────────────────────────────────
  # P0: record_usage/2 — bridges to SpendingLimits
  # ──────────────────────────────────────────────

  describe "record_usage/2 delegation" do
    test "returns :ok when no linked settings_user" do
      user = create_chat_user()
      assert :ok = Enforcer.record_usage(user.id, %{cost: 0.05})
    end

    test "returns :ok when no spending limit configured" do
      {user, _settings_user} = create_linked_settings_user()
      assert :ok = Enforcer.record_usage(user.id, %{cost: 0.05})
    end

    test "records usage when spending limit exists" do
      {user, settings_user} = create_linked_settings_user()
      create_spending_limit(settings_user)

      assert :ok = Enforcer.record_usage(user.id, %{cost: 0.50, prompt_tokens: 1000, completion_tokens: 500})

      {period_start, _} = current_period_dates(1)
      record = Repo.get_by(UsageRecord, settings_user_id: settings_user.id, period_start: period_start)

      assert record.total_cost_cents == 50
      assert record.call_count == 1
    end

    test "always returns :ok even after delegation" do
      {user, settings_user} = create_linked_settings_user()
      create_spending_limit(settings_user)

      # The Enforcer.record_usage always returns :ok (swallows downstream errors)
      assert :ok = Enforcer.record_usage(user.id, %{cost: 0.10})
    end
  end
end

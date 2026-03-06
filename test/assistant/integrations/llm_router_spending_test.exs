defmodule Assistant.Integrations.LLMRouterSpendingTest do
  @moduledoc """
  Tests for the spending limit enforcement in LLMRouter.chat_completion/3.

  Covers:
    - Over budget -> returns {:error, :over_budget} (throw/catch mechanism)
    - Warning threshold -> logs but continues (makes LLM call)
    - Under budget -> proceeds normally
    - skip_spending_check: true -> bypasses check entirely (sentinel exemption)
    - nil user_id -> no check (system calls)
  """
  use Assistant.DataCase, async: true

  alias Assistant.Integrations.LLMRouter
  alias Assistant.Schemas.{SpendingLimit, UsageRecord}

  import Assistant.AccountsFixtures

  # --- Helpers ---

  defp create_linked_pair do
    settings_user = settings_user_fixture()

    {:ok, user} =
      %Assistant.Schemas.User{}
      |> Assistant.Schemas.User.changeset(%{
        external_id: "test-#{System.unique_integer([:positive])}",
        channel: "test"
      })
      |> Repo.insert()

    settings_user
    |> Ecto.Changeset.change(user_id: user.id)
    |> Repo.update!()

    {user, Repo.get!(Assistant.Accounts.SettingsUser, settings_user.id)}
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

  defp insert_usage(settings_user_id, cost_cents) do
    {period_start, period_end} = current_period_dates(1)

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

  # --- Tests ---

  describe "chat_completion/3 spending enforcement" do
    test "returns {:error, :over_budget} when user is over hard cap" do
      {user, settings_user} = create_linked_pair()
      create_spending_limit(settings_user, %{budget_cents: 1_000, hard_cap: true})
      insert_usage(settings_user.id, 1_500)

      # The call should never reach an LLM provider — it should throw/catch
      # and return {:error, :over_budget} before any HTTP call
      result =
        LLMRouter.chat_completion(
          [%{role: "user", content: "hello"}],
          [model: "openai/gpt-5-mini"],
          user.id
        )

      assert {:error, :over_budget} = result
    end

    test "returns {:error, :over_budget} when usage exactly equals budget (hard cap)" do
      {user, settings_user} = create_linked_pair()
      create_spending_limit(settings_user, %{budget_cents: 5_000, hard_cap: true})
      insert_usage(settings_user.id, 5_000)

      result =
        LLMRouter.chat_completion(
          [%{role: "user", content: "hello"}],
          [model: "openai/gpt-5-mini"],
          user.id
        )

      assert {:error, :over_budget} = result
    end

    test "bypasses spending check when skip_spending_check: true" do
      {user, settings_user} = create_linked_pair()
      create_spending_limit(settings_user, %{budget_cents: 100, hard_cap: true})
      insert_usage(settings_user.id, 500)

      # With skip_spending_check, the call proceeds past the budget check.
      # It will fail at the actual LLM call (no real API key), but the point
      # is it does NOT return {:error, :over_budget}.
      result =
        LLMRouter.chat_completion(
          [%{role: "user", content: "hello"}],
          [model: "openai/gpt-5-mini", skip_spending_check: true],
          user.id
        )

      # The result should be an error from the actual provider call, NOT :over_budget
      assert {:error, reason} = result
      assert reason != :over_budget
    end

    test "allows call for nil user_id (system/internal calls)" do
      # nil user_id should bypass the spending check entirely.
      # The call will fail at the provider level, but not with :over_budget.
      result =
        LLMRouter.chat_completion(
          [%{role: "user", content: "hello"}],
          [model: "openai/gpt-5-mini"],
          nil
        )

      assert {:error, reason} = result
      assert reason != :over_budget
    end

    test "allows call when no spending limit is configured" do
      {user, _settings_user} = create_linked_pair()

      # No spending limit created — should bypass check.
      # Will fail at provider, but not with :over_budget.
      result =
        LLMRouter.chat_completion(
          [%{role: "user", content: "hello"}],
          [model: "openai/gpt-5-mini"],
          user.id
        )

      assert {:error, reason} = result
      assert reason != :over_budget
    end

    test "allows call when under budget" do
      {user, settings_user} = create_linked_pair()
      create_spending_limit(settings_user, %{budget_cents: 10_000, hard_cap: true})
      insert_usage(settings_user.id, 2_000)

      # Under budget — should pass spending check and proceed to LLM call.
      result =
        LLMRouter.chat_completion(
          [%{role: "user", content: "hello"}],
          [model: "openai/gpt-5-mini"],
          user.id
        )

      assert {:error, reason} = result
      assert reason != :over_budget
    end

    test "soft cap does not block call even when over budget" do
      {user, settings_user} = create_linked_pair()
      create_spending_limit(settings_user, %{budget_cents: 1_000, hard_cap: false, warning_threshold: 80})
      insert_usage(settings_user.id, 2_000)

      # Soft cap: over budget but no block — just warning logged.
      result =
        LLMRouter.chat_completion(
          [%{role: "user", content: "hello"}],
          [model: "openai/gpt-5-mini"],
          user.id
        )

      assert {:error, reason} = result
      assert reason != :over_budget
    end
  end
end

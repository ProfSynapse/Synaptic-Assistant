defmodule Assistant.Billing.MeteringTest do
  use Assistant.DataCase, async: false

  alias Assistant.AccountsFixtures
  alias Assistant.Billing
  alias Assistant.Billing.Metering
  alias Assistant.Repo

  alias Assistant.Schemas.{
    BillingAccount,
    BillingUsageSnapshot,
    Conversation,
    MemoryEntry,
    Message,
    SyncedFile,
    User
  }

  describe "current_usage/1" do
    test "aggregates retained bytes across files, messages, and memory for a billing account" do
      settings_user = AccountsFixtures.settings_user_fixture()
      {:ok, {_, billing_account}} = Billing.ensure_billing_account(settings_user)

      {:ok, billing_account} =
        billing_account
        |> BillingAccount.changeset(%{plan: "pro", billing_mode: "manual"})
        |> Repo.update()

      user_one = insert_user(billing_account.id, "alpha")
      user_two = insert_user(billing_account.id, "beta")

      {:ok, conversation} =
        %Conversation{}
        |> Conversation.changeset(%{channel: "chat", user_id: user_one.id})
        |> Repo.insert()

      {:ok, _message} =
        %Message{}
        |> Message.changeset(%{
          role: "assistant",
          conversation_id: conversation.id,
          content: "hello"
        })
        |> Repo.insert()

      {:ok, _synced_file} =
        %SyncedFile{}
        |> SyncedFile.changeset(%{
          user_id: user_two.id,
          drive_file_id: "drive-file-1",
          drive_file_name: "note.md",
          drive_mime_type: "text/markdown",
          local_path: "note.md",
          local_format: "md",
          file_size: byte_size("drive"),
          content: "drive"
        })
        |> Repo.insert()

      {:ok, _memory_entry} =
        %MemoryEntry{}
        |> MemoryEntry.changeset(%{
          user_id: user_two.id,
          title: "memory",
          content: "remember"
        })
        |> Repo.insert()

      assert {:ok, usage} = Metering.current_usage(billing_account.id)

      assert usage.billing_account_id == billing_account.id
      assert usage.plan == "pro"
      assert usage.seat_count == 1
      assert usage.included_bytes == 10_000_000_000
      assert usage.synced_file_bytes == byte_size("drive")
      assert usage.message_bytes == byte_size("hello")
      assert usage.memory_bytes == byte_size("memory") + byte_size("remember")

      assert usage.total_bytes ==
               usage.synced_file_bytes + usage.message_bytes + usage.memory_bytes

      assert usage.overage_bytes == 0
      assert usage.overage_units == 0

      assert {:ok, snapshot_attrs} =
               Metering.snapshot_attrs(billing_account.id, ~U[2026-03-01 12:00:00Z])

      assert snapshot_attrs.measured_at == ~U[2026-03-01 12:00:00Z]
      assert snapshot_attrs.total_bytes == usage.total_bytes
      assert snapshot_attrs.overage_bytes == usage.overage_bytes
    end

    test "uses effective billing entitlements including manual overrides and bonuses" do
      settings_user = AccountsFixtures.settings_user_fixture()
      {:ok, {_, billing_account}} = Billing.ensure_billing_account(settings_user)

      {:ok, billing_account} =
        billing_account
        |> BillingAccount.changeset(%{
          plan: "pro",
          billing_mode: "manual",
          seat_bonus: 2,
          storage_bonus_bytes: 3_000_000_000
        })
        |> Repo.update()

      assert {:ok, usage} = Metering.current_usage(billing_account.id)

      assert usage.plan == "pro"
      assert usage.seat_count == 1
      assert usage.included_bytes == 33_000_000_000
      assert usage.overage_bytes == 0
    end

    test "treats pending Stripe activation as pro entitlement" do
      settings_user = AccountsFixtures.settings_user_fixture()
      {:ok, {_, billing_account}} = Billing.ensure_billing_account(settings_user)

      {:ok, billing_account} =
        billing_account
        |> BillingAccount.changeset(%{
          plan: "free",
          billing_mode: "standard",
          stripe_subscription_status: "pending_activation"
        })
        |> Repo.update()

      assert {:ok, usage} = Metering.current_usage(billing_account.id)

      assert usage.plan == "pro"
      assert usage.included_bytes == 10_000_000_000
    end
  end

  describe "average_overage_bytes/3" do
    test "averages hourly snapshot overage and converts to whole Stripe units" do
      settings_user = AccountsFixtures.settings_user_fixture()
      {:ok, {_, billing_account}} = Billing.ensure_billing_account(settings_user)

      period_start = ~U[2026-03-01 00:00:00Z]
      period_end = ~U[2026-03-01 04:00:00Z]

      for {measured_at, overage_bytes} <- [
            {period_start, 0},
            {DateTime.add(period_start, 1, :hour), 1_000_000_000},
            {DateTime.add(period_start, 2, :hour), 2_000_000_000},
            {DateTime.add(period_start, 3, :hour), 3_000_000_000},
            {period_end, 9_999_999_999}
          ] do
        {:ok, _snapshot} =
          %BillingUsageSnapshot{}
          |> BillingUsageSnapshot.changeset(%{
            billing_account_id: billing_account.id,
            measured_at: measured_at,
            seat_count: 1,
            included_bytes: 10_000_000_000,
            synced_file_bytes: 0,
            message_bytes: 0,
            memory_bytes: 0,
            total_bytes: overage_bytes + 10_000_000_000,
            overage_bytes: overage_bytes
          })
          |> Repo.insert()
      end

      assert Metering.average_overage_bytes(billing_account.id, period_start, period_end) ==
               1_500_000_000

      assert Metering.average_overage_units(billing_account.id, period_start, period_end) == 2
      assert Metering.bytes_to_overage_units(1_500_000_000) == 2
      assert Metering.bytes_to_overage_units(0) == 0
    end
  end

  defp insert_user(billing_account_id, prefix) do
    %User{}
    |> User.changeset(%{
      external_id: "#{prefix}-#{System.unique_integer([:positive])}",
      channel: "test",
      billing_account_id: billing_account_id
    })
    |> Repo.insert!()
  end
end

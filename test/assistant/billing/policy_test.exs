defmodule Assistant.Billing.PolicyTest do
  use Assistant.DataCase, async: false

  alias Assistant.AccountsFixtures
  alias Assistant.Billing
  alias Assistant.Billing.Policy
  alias Assistant.ChannelFixtures
  alias Assistant.Repo

  alias Assistant.Schemas.{
    BillingAccount,
    SyncedFile
  }

  test "blocks free-tier retained writes that would exceed the storage cap" do
    settings_user = AccountsFixtures.settings_user_fixture()
    {:ok, {_, billing_account}} = Billing.ensure_billing_account(settings_user)
    user = ChannelFixtures.chat_user_fixture(%{billing_account_id: billing_account.id})

    {:ok, _synced_file} =
      %SyncedFile{}
      |> SyncedFile.changeset(%{
        user_id: user.id,
        drive_file_id: "file-1",
        drive_file_name: "cap.txt",
        drive_mime_type: "text/plain",
        local_path: "cap.txt",
        local_format: "txt",
        content: String.duplicate("a", 25_000_000)
      })
      |> Repo.insert()

    assert {:error, {:storage_limit_exceeded, details}} =
             Policy.ensure_retained_write_allowed(user.id, 1)

    assert details.plan == "free"
    assert details.included_bytes == 25_000_000
    assert details.projected_bytes == 25_000_001
  end

  test "allows retained writes on pro even when usage is above the included free cap" do
    settings_user = AccountsFixtures.settings_user_fixture()
    {:ok, {_, billing_account}} = Billing.ensure_billing_account(settings_user)

    {:ok, billing_account} =
      billing_account
      |> BillingAccount.changeset(%{plan: "pro", billing_mode: "manual"})
      |> Repo.update()

    user = ChannelFixtures.chat_user_fixture(%{billing_account_id: billing_account.id})

    assert :ok = Policy.ensure_retained_write_allowed(user.id, 50_000_000)
  end
end

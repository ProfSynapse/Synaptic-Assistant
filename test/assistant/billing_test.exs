defmodule Assistant.BillingTest do
  use Assistant.DataCase, async: false

  alias Assistant.Accounts
  alias Assistant.Billing
  alias Assistant.Repo
  alias Assistant.Schemas.{BillingAccount, User}

  import Assistant.AccountsFixtures
  import Assistant.ChannelFixtures

  describe "ensure_billing_account/1" do
    test "creates an owner-scoped billing account for an existing settings user" do
      settings_user = settings_user_fixture()

      assert {:ok, {updated_user, billing_account}} =
               Billing.ensure_billing_account(settings_user)

      assert updated_user.billing_account_id == billing_account.id
      assert updated_user.billing_role == "owner"
      assert billing_account.plan == "free"
      assert billing_account.billing_email == settings_user.email
    end

    test "syncs the linked chat user onto the billing account" do
      user = chat_user_fixture(%{email: unique_settings_user_email()})

      settings_user =
        settings_user_fixture(%{email: user.email})
        |> Ecto.Changeset.change(user_id: user.id)
        |> Repo.update!()

      assert {:ok, {_updated_user, billing_account}} =
               Billing.ensure_billing_account(settings_user)

      assert Repo.get!(User, user.id).billing_account_id == billing_account.id
    end
  end

  describe "create_settings_user_from_admin/2" do
    test "assigns new users to the creator billing account" do
      admin = admin_settings_user_fixture()
      {:ok, {_, billing_account}} = Billing.ensure_billing_account(admin)

      {:ok, created_user} =
        Accounts.create_settings_user_from_admin(
          %{
            email: unique_settings_user_email(),
            full_name: "Billing Member",
            is_admin: false,
            access_scopes: ["chat"]
          },
          billing_account_id: billing_account.id
        )

      assert created_user.billing_account_id == billing_account.id
      assert created_user.billing_role == "member"
    end
  end

  describe "sync_linked_user_billing_account_by_user_id/1" do
    test "clears the chat user billing account when membership is removed" do
      settings_user = settings_user_fixture()
      {:ok, {settings_user, billing_account}} = Billing.ensure_billing_account(settings_user)

      user =
        chat_user_fixture(%{
          email: settings_user.email,
          billing_account_id: billing_account.id
        })

      settings_user
      |> Ecto.Changeset.change(user_id: user.id, billing_account_id: nil)
      |> Repo.update!()

      assert :ok = Billing.sync_linked_user_billing_account_by_user_id(user.id)
      assert Repo.get!(User, user.id).billing_account_id == nil
    end
  end

  describe "workspace billing overrides" do
    test "applies seat and storage bonuses to pro storage policy" do
      settings_user = settings_user_fixture()
      {:ok, {_, billing_account}} = Billing.ensure_billing_account(settings_user)

      assert {:ok, billing_account} =
               Billing.update_billing_account_overrides(billing_account.id, %{
                 "plan" => "pro",
                 "billing_mode" => "manual",
                 "seat_bonus" => "2",
                 "storage_bonus_gb" => "3"
               })

      policy = Billing.storage_policy(billing_account)

      assert policy.plan == "pro"
      assert policy.billing_mode == "manual"
      assert policy.seat_count == 1
      assert policy.seat_bonus == 2
      assert policy.storage_bonus_bytes == 3_000_000_000
      assert policy.included_bytes == 33_000_000_000
      assert policy.hard_limit_bytes == nil
    end

    test "extends the free hard limit with bonus storage" do
      settings_user = settings_user_fixture()
      {:ok, {_, billing_account}} = Billing.ensure_billing_account(settings_user)

      assert {:ok, billing_account} =
               Billing.update_billing_account_overrides(billing_account.id, %{
                 "plan" => "free",
                 "billing_mode" => "manual",
                 "storage_bonus_gb" => "2"
               })

      policy = Billing.storage_policy(billing_account)

      assert policy.plan == "free"
      assert policy.included_bytes == 2_025_000_000
      assert policy.hard_limit_bytes == 2_025_000_000
    end

    test "skips Stripe overage reporting for complimentary workspaces" do
      settings_user = settings_user_fixture()
      {:ok, {_, billing_account}} = Billing.ensure_billing_account(settings_user)

      assert {:ok, billing_account} =
               Billing.update_billing_account_overrides(billing_account.id, %{
                 "plan" => "pro",
                 "billing_mode" => "complimentary"
               })

      assert {:error, :skip} = Billing.report_overage_to_stripe(billing_account)
    end

    test "rejects malformed override input instead of silently clearing values" do
      settings_user = settings_user_fixture()
      {:ok, {_, billing_account}} = Billing.ensure_billing_account(settings_user)

      assert {:error, changeset} =
               Billing.update_billing_account_overrides(billing_account.id, %{
                 "plan" => "pro",
                 "billing_mode" => "complimentary",
                 "complimentary_until" => "2026-04-01T12:30",
                 "storage_bonus_gb" => "2.5"
               })

      assert "must be an ISO8601 UTC timestamp like 2026-04-01T12:30:00Z" in errors_on(changeset).complimentary_until

      assert "must be a whole number of GB" in errors_on(changeset).storage_bonus_bytes
    end
  end

  describe "billing_snapshot/2" do
    test "can read billing state without creating a billing account" do
      settings_user = settings_user_fixture()

      snapshot = Billing.billing_snapshot(settings_user)

      assert snapshot.billing_account == nil
      assert snapshot.billing_summary.plan == "free"
      assert snapshot.storage_policy.included_bytes == Billing.free_storage_limit_bytes()
      refute Repo.get!(Assistant.Accounts.SettingsUser, settings_user.id).billing_account_id
    end
  end

  describe "process_webhook/2" do
    setup do
      prev = Application.get_env(:assistant, :stripe_webhook_secret)
      Application.put_env(:assistant, :stripe_webhook_secret, "whsec_test")

      on_exit(fn ->
        if prev do
          Application.put_env(:assistant, :stripe_webhook_secret, prev)
        else
          Application.delete_env(:assistant, :stripe_webhook_secret)
        end
      end)

      :ok
    end

    test "updates the shared billing account from a subscription webhook" do
      settings_user = settings_user_fixture()
      {:ok, {_, billing_account}} = Billing.ensure_billing_account(settings_user)

      {:ok, billing_account} =
        billing_account
        |> BillingAccount.changeset(%{stripe_customer_id: "cus_123"})
        |> Repo.update()

      payload = %{
        "type" => "customer.subscription.updated",
        "data" => %{
          "object" => %{
            "id" => "sub_123",
            "customer" => "cus_123",
            "status" => "active",
            "current_period_end" => 1_773_935_200,
            "items" => %{
              "data" => [
                %{
                  "id" => "si_123",
                  "price" => %{"id" => "price_pro_123"}
                }
              ]
            },
            "metadata" => %{"billing_account_id" => billing_account.id}
          }
        }
      }

      raw_body = Jason.encode!(payload)

      assert :ok = Billing.process_webhook(signature_for(raw_body, "whsec_test"), raw_body)

      billing_account = Repo.get!(BillingAccount, billing_account.id)
      assert billing_account.plan == "pro"
      assert billing_account.stripe_subscription_id == "sub_123"
      assert billing_account.stripe_subscription_item_id == "si_123"
      assert billing_account.stripe_price_id == "price_pro_123"
      assert billing_account.stripe_subscription_status == "active"
    end

    test "keeps pro access after checkout completion before the subscription webhook arrives" do
      settings_user = settings_user_fixture()
      {:ok, {settings_user, billing_account}} = Billing.ensure_billing_account(settings_user)

      payload = %{
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "customer" => "cus_checkout",
            "subscription" => "sub_checkout",
            "metadata" => %{"billing_account_id" => billing_account.id}
          }
        }
      }

      raw_body = Jason.encode!(payload)

      assert :ok = Billing.process_webhook(signature_for(raw_body, "whsec_test"), raw_body)

      billing_account = Repo.get!(BillingAccount, billing_account.id)

      summary =
        Billing.billing_summary_for_account(billing_account, billing_email: settings_user.email)

      assert billing_account.stripe_subscription_status == "pending_activation"
      assert summary.plan == "pro"
    end

    test "preserves manual exceptions when Stripe sends deletion webhooks" do
      settings_user = settings_user_fixture()
      {:ok, {_, billing_account}} = Billing.ensure_billing_account(settings_user)

      {:ok, billing_account} =
        billing_account
        |> BillingAccount.changeset(%{
          stripe_customer_id: "cus_manual",
          stripe_subscription_id: "sub_manual",
          stripe_subscription_status: "active",
          plan: "pro",
          billing_mode: "manual"
        })
        |> Repo.update()

      payload = %{
        "type" => "customer.subscription.deleted",
        "data" => %{
          "object" => %{
            "id" => "sub_manual",
            "customer" => "cus_manual",
            "status" => "canceled",
            "metadata" => %{"billing_account_id" => billing_account.id}
          }
        }
      }

      raw_body = Jason.encode!(payload)

      assert :ok = Billing.process_webhook(signature_for(raw_body, "whsec_test"), raw_body)

      billing_account = Repo.get!(BillingAccount, billing_account.id)
      assert billing_account.plan == "pro"
      assert billing_account.billing_mode == "manual"
      assert billing_account.stripe_subscription_id == nil
      assert billing_account.stripe_subscription_status == "canceled"
    end
  end

  defp signature_for(raw_body, secret) do
    timestamp = Integer.to_string(System.system_time(:second))

    digest =
      :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{raw_body}")
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{digest}"
  end
end

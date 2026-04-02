defmodule AssistantWeb.SettingsLive.ProfileBillingTest do
  use Assistant.DataCase, async: true

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest

  alias Assistant.Accounts.Scope
  alias AssistantWeb.Components.SettingsPage.Profile
  alias AssistantWeb.SettingsLive.Loaders

  import Assistant.AccountsFixtures

  test "load_profile adds billing storage state and the profile card renders the storage copy" do
    settings_user = settings_user_fixture(%{email: unique_settings_user_email()})

    socket = %Phoenix.LiveView.Socket{
      assigns: %{current_scope: Scope.for_settings_user(settings_user), __changed__: %{}}
    }

    socket = Loaders.load_profile(socket)

    assert socket.assigns.billing_storage.included_label == "25 MB"
    assert socket.assigns.billing_storage.current_label == "0 B"
    assert socket.assigns.billing_storage.projected_overage_label == "0 B"
    assert socket.assigns.billing_storage.metering_available? == true

    html =
      render_component(&Profile.profile_section/1,
        profile: socket.assigns.profile,
        profile_form: to_form(socket.assigns.profile, as: :profile),
        billing_summary: socket.assigns.billing_summary,
        billing_storage: socket.assigns.billing_storage,
        orchestrator_prompt_html: "<p>Prompt</p>",
        onboarding_checklist_items: [],
        onboarding_all_complete?: true,
        onboarding_dismissed?: true
      )

    assert html =~ "Workspace Billing"
    assert html =~ "Included Storage"
    assert html =~ "Current Retained Storage"
    assert html =~ "Projected Overage"
    assert html =~ "average retained storage across the full billing month"
    refute html =~ "Storage metering is not active yet"
  end

  test "profile billing card hides Stripe actions while an internal override is active" do
    html =
      render_component(&Profile.profile_section/1,
        profile: %{},
        profile_form: to_form(%{}, as: :profile),
        billing_summary: %{
          account_name: "Workspace",
          plan: "pro",
          billing_mode: "manual",
          stripe_subscription_status: "active",
          seat_count: 1,
          seat_bonus: 0,
          storage_bonus_bytes: 0,
          billing_email: "owner@example.com",
          current_period_end: nil,
          complimentary_until: nil,
          can_manage?: true
        },
        billing_storage: %{
          included_label: "10 GB",
          current_label: "1 GB",
          projected_overage_label: "0 B",
          plan_note: "Manual override active.",
          metering_available?: true
        },
        orchestrator_prompt_html: "<p>Prompt</p>",
        onboarding_checklist_items: [],
        onboarding_all_complete?: true,
        onboarding_dismissed?: true
      )

    assert html =~ "internal billing override"
    refute html =~ "Start Pro Checkout"
    refute html =~ "Open Billing Portal"
  end

  test "profile billing card hides Stripe actions in self-hosted mode" do
    previous_mode = Application.get_env(:assistant, :deployment_mode)
    Application.put_env(:assistant, :deployment_mode, :self_hosted)

    on_exit(fn ->
      Application.put_env(:assistant, :deployment_mode, previous_mode || :cloud)
    end)

    html =
      render_component(&Profile.profile_section/1,
        profile: %{},
        profile_form: to_form(%{}, as: :profile),
        billing_summary: %{
          account_name: "Workspace",
          plan: "free",
          billing_mode: "standard",
          stripe_subscription_status: nil,
          seat_count: 1,
          seat_bonus: 0,
          storage_bonus_bytes: 0,
          billing_email: "owner@example.com",
          current_period_end: nil,
          complimentary_until: nil,
          can_manage?: true
        },
        billing_storage: %{
          included_label: "25 MB",
          current_label: "1 MB",
          projected_overage_label: "0 B",
          plan_note: "Free workspaces stop taking on new retained storage once they hit 25 MB.",
          metering_available?: true
        },
        orchestrator_prompt_html: "<p>Prompt</p>",
        onboarding_checklist_items: [],
        onboarding_all_complete?: true,
        onboarding_dismissed?: true
      )

    assert html =~ "self-hosted"
    refute html =~ "Start Pro Checkout"
    refute html =~ "Open Billing Portal"
  end
end

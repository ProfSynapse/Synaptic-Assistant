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
        orchestrator_prompt_html: "<p>Prompt</p>"
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
        orchestrator_prompt_html: "<p>Prompt</p>"
      )

    assert html =~ "internal billing override"
    refute html =~ "Start Pro Checkout"
    refute html =~ "Open Billing Portal"
  end
end

defmodule AssistantWeb.Components.SettingsPage do
  @moduledoc false

  use AssistantWeb, :html

  alias AssistantWeb.Components.SettingsPage.Helpers

  import AssistantWeb.Components.SettingsPage.Admin,
    only: [admin_integration_detail_section: 1, admin_section: 1]
  import AssistantWeb.Components.SettingsPage.Analytics, only: [analytics_section: 1]
  import AssistantWeb.Components.SettingsPage.AppDetail, only: [app_detail_section: 1]
  import AssistantWeb.Components.SettingsPage.Apps, only: [apps_section: 1]
  import AssistantWeb.Components.SettingsPage.Help, only: [help_section: 1]
  import AssistantWeb.Components.SettingsPage.Memory, only: [memory_section: 1]
  import AssistantWeb.Components.SettingsPage.Profile, only: [profile_section: 1]
  import AssistantWeb.Components.SettingsPage.Workflows, only: [workflows_section: 1]

  def settings_page(assigns) do
    is_admin =
      case assigns[:current_scope] do
        %{settings_user: %{is_admin: true}} -> true
        _ -> false
      end

    current_scope = assigns[:current_scope]

    assigns =
      assigns
      |> assign(:is_admin, is_admin)
      |> assign(:nav_current_scope, current_scope)

    ~H"""
    <div class="sa-settings-shell">
      <aside class={["sa-sidebar", @sidebar_collapsed && "is-collapsed"]}>
        <div class="sa-sidebar-header">
          <div class="sa-sidebar-brand">
            <img src="/images/aperture.png" alt="Synaptic Assistant" class="sa-brand-mark" />
            <span :if={!@sidebar_collapsed}>Synaptic Assistant</span>
          </div>
          <button
            type="button"
            class="sa-icon-btn sa-sidebar-toggle"
            phx-click="toggle_sidebar"
            aria-label="Toggle sidebar"
          >
            <.icon name="hero-bars-3" class="h-4 w-4" />
          </button>
        </div>

        <nav class="sa-sidebar-nav">
          <.link
            :for={{section, label} <- Helpers.nav_items_for(@nav_current_scope || @is_admin)}
            navigate={
              cond do
                section == "profile" -> ~p"/settings"
                section == "workspace" -> ~p"/workspace"
                true -> ~p"/settings/#{section}"
              end
            }
            class={["sa-sidebar-link", section == @section && "is-active"]}
            title={label}
          >
            <.icon name={Helpers.icon_for(section)} class="h-4 w-4" />
            <span :if={!@sidebar_collapsed}>{label}</span>
          </.link>
        </nav>

        <div class="sa-sidebar-footer">
          <.link href={~p"/settings_users/log-out"} method="delete" class="sa-sidebar-link" title="Log Out">
            <.icon name="hero-arrow-right-on-rectangle" class="h-4 w-4" />
            <span :if={!@sidebar_collapsed}>Log Out</span>
          </.link>
        </div>
      </aside>

      <section class="sa-content">
        <header :if={!@current_app and !@current_admin_integration} class="sa-page-header">
          <h1>{Helpers.page_title(@section)}</h1>
          <p :if={@section == "profile"} class="sa-page-subtitle">
            Welcome back, {Helpers.profile_first_name(@profile)}.
          </p>
        </header>

        <.app_detail_section :if={@current_app} {assigns} />
        <.admin_integration_detail_section
          :if={@section == "admin" and @is_admin and @current_admin_integration}
          {assigns}
        />
        <.profile_section :if={@section == "profile" and !@current_app} {assigns} />
        <.analytics_section :if={@section == "analytics" and !@current_app} {assigns} />
        <.memory_section :if={@section == "memory" and !@current_app} {assigns} />
        <.apps_section :if={@section == "apps" and !@current_app} {assigns} />
        <.workflows_section :if={@section == "workflows" and !@current_app} {assigns} />
        <.admin_section
          :if={@section == "admin" and @is_admin and !@current_app and !@current_admin_integration}
          {assigns}
        />
        <.help_section :if={@section == "help" and !@current_app} {assigns} />
      </section>
    </div>
    """
  end
end

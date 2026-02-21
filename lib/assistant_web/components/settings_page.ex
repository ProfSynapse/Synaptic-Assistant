defmodule AssistantWeb.Components.SettingsPage do
  @moduledoc false

  use AssistantWeb, :html

  alias AssistantWeb.Components.SettingsPage.Helpers

  import AssistantWeb.Components.SettingsPage.Analytics, only: [analytics_section: 1]
  import AssistantWeb.Components.SettingsPage.Apps, only: [apps_section: 1]
  import AssistantWeb.Components.SettingsPage.Help, only: [help_section: 1]
  import AssistantWeb.Components.SettingsPage.Memory, only: [memory_section: 1]
  import AssistantWeb.Components.SettingsPage.Models, only: [models_section: 1]
  import AssistantWeb.Components.SettingsPage.Profile, only: [profile_section: 1]
  import AssistantWeb.Components.SettingsPage.Skills, only: [skills_section: 1]
  import AssistantWeb.Components.SettingsPage.Workflows, only: [workflows_section: 1]

  def settings_page(assigns) do
    ~H"""
    <div class="sa-settings-shell">
      <aside class={["sa-sidebar", @sidebar_collapsed && "is-collapsed"]}>
        <div class="sa-sidebar-header">
          <div class="sa-sidebar-brand">
            <div class="sa-brand-mark">A</div>
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
            :for={{section, label} <- Helpers.nav_items()}
            navigate={if(section == "profile", do: ~p"/settings", else: ~p"/settings/#{section}")}
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
        <header class="sa-page-header">
          <h1>{Helpers.page_title(@section)}</h1>
          <p :if={@section == "profile"} class="sa-page-subtitle">
            Welcome back, {Helpers.profile_first_name(@profile)}.
          </p>
        </header>

        <.profile_section :if={@section == "profile"} {assigns} />
        <.models_section :if={@section == "models"} {assigns} />
        <.analytics_section :if={@section == "analytics"} {assigns} />
        <.memory_section :if={@section == "memory"} {assigns} />
        <.apps_section :if={@section == "apps"} {assigns} />
        <.workflows_section :if={@section == "workflows"} {assigns} />
        <.skills_section :if={@section == "skills"} {assigns} />
        <.help_section :if={@section == "help"} {assigns} />
      </section>
    </div>
    """
  end
end

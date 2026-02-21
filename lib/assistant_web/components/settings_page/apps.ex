defmodule AssistantWeb.Components.SettingsPage.Apps do
  @moduledoc false

  use AssistantWeb, :html

  alias Phoenix.LiveView.JS

  alias Assistant.Integrations.Google.Auth, as: GoogleAuth

  import AssistantWeb.Components.ConnectorCard, only: [connector_card: 1]
  import AssistantWeb.Components.DriveSettings, only: [drive_settings: 1]

  def apps_section(assigns) do
    ~H"""
    <section class="sa-card">
      <div class="sa-row">
        <h2>Connected Apps</h2>
        <button class="sa-btn" type="button" phx-click="open_add_app_modal">
          <.icon name="hero-plus" class="h-4 w-4" /> Add App
        </button>
      </div>

      <p>Only approved apps from the platform catalog can be connected.</p>

      <div class="sa-card-grid">
        <.connector_card
          :for={app <- @app_catalog}
          id={app.id}
          name={app.name}
          icon_path={app.icon_path}
          connected={app.id == "google_workspace" and @google_connected}
          on_connect={if(app.id == "google_workspace", do: "connect_google", else: "")}
          on_disconnect={if(app.id == "google_workspace", do: "disconnect_google", else: "")}
          disconnect_confirm="Disconnect Google Workspace?"
          disabled={app.id != "google_workspace"}
        />
      </div>

      <.drive_settings
        :if={@google_connected}
        connected_drives={@connected_drives}
        available_drives={@available_drives}
        drives_loading={@drives_loading}
        has_google_token={GoogleAuth.configured?()}
      />
      <div :if={!@google_connected} class="sa-drive-settings">
        <h3>Google Drive Access</h3>
        <div class="sa-drive-notice sa-drive-notice--info">
          <.icon name="hero-information-circle" class="h-5 w-5" />
          <span>Connect your Google account above to manage Drive access.</span>
        </div>
      </div>

      <.modal
        :if={@apps_modal_open}
        id="apps-modal"
        title="Add App"
        max_width="lg"
        on_cancel={JS.push("close_add_app_modal")}
      >
        <div class="sa-card-grid">
          <article :for={app <- @app_catalog} class="sa-card">
            <div class="sa-row" style="margin-bottom: 1rem;">
              <div class="sa-app-title" style="margin-bottom: 0;">
                <img src={app.icon_path} alt={app.name} class="sa-app-icon" />
                <h4 style="margin: 0;">{app.name}</h4>
              </div>
            </div>
            <button
              type="button"
              class="sa-btn secondary"
              style="width: 100%; justify-content: center;"
              phx-click="add_catalog_app"
              phx-value-id={app.id}
            >
              Add
            </button>
          </article>
        </div>
      </.modal>
    </section>
    """
  end
end

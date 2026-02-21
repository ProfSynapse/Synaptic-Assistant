defmodule AssistantWeb.Components.DriveSettings do
  @moduledoc false

  use Phoenix.Component

  import AssistantWeb.CoreComponents, only: [icon: 1]

  attr :connected_drives, :list, required: true
  attr :available_drives, :list, required: true
  attr :drives_loading, :boolean, default: false
  attr :has_google_token, :boolean, default: false

  def drive_settings(assigns) do
    personal_connected = has_personal_drive?(assigns.connected_drives)

    available_not_connected =
      filter_unconnected(assigns.available_drives, assigns.connected_drives)

    assigns =
      assigns
      |> assign(:personal_connected, personal_connected)
      |> assign(:available_not_connected, available_not_connected)

    ~H"""
    <div class="sa-drive-settings">
      <div class="sa-row">
        <div>
          <h3>Google Drive Access</h3>
          <p class="sa-muted">Choose which drives the assistant can search and access.</p>
        </div>
        <button
          :if={@has_google_token}
          type="button"
          class="sa-btn secondary"
          phx-click="refresh_drives"
          disabled={@drives_loading}
        >
          <.icon name="hero-arrow-path" class={["h-4 w-4", @drives_loading && "sa-spin"]} />
          {if @drives_loading, do: "Refreshing...", else: "Refresh Drives"}
        </button>
      </div>

      <div :if={!@has_google_token} class="sa-drive-notice">
        <.icon name="hero-exclamation-triangle" class="h-5 w-5" />
        <span>Google API credentials are not configured. Drive management requires a valid service account.</span>
      </div>

      <div :if={@has_google_token}>
        <div :if={@connected_drives == [] and !@drives_loading} class="sa-drive-notice sa-drive-notice--info">
          <.icon name="hero-information-circle" class="h-5 w-5" />
          <span>No drives connected yet. Click "Refresh Drives" to discover available shared drives, or connect your personal drive below.</span>
        </div>

        <div :if={@connected_drives != []} class="sa-drive-list">
          <div
            :for={drive <- @connected_drives}
            class="sa-drive-row"
          >
            <div class="sa-drive-info">
              <.icon
                name={drive_icon(drive.drive_type)}
                class="h-5 w-5 sa-drive-icon"
              />
              <div>
                <span class="sa-drive-name">{drive.drive_name}</span>
                <span class="sa-drive-type">{drive_type_label(drive.drive_type)}</span>
              </div>
            </div>
            <div class="sa-drive-actions">
              <label class="sa-switch">
                <input
                  type="checkbox"
                  checked={drive.enabled}
                  class="sa-switch-input"
                  role="switch"
                  aria-checked={to_string(drive.enabled)}
                  aria-label={"Toggle access to #{drive.drive_name}"}
                  phx-click="toggle_drive"
                  phx-value-id={drive.id}
                  phx-value-enabled={to_string(!drive.enabled)}
                />
                <span class="sa-switch-slider"></span>
              </label>
              <button
                :if={drive.drive_type == "shared"}
                type="button"
                class="sa-icon-btn sa-drive-disconnect"
                title={"Disconnect #{drive.drive_name}"}
                aria-label={"Disconnect #{drive.drive_name}"}
                phx-click="disconnect_drive"
                phx-value-id={drive.id}
                data-confirm={"Disconnect #{drive.drive_name}? The assistant will no longer be able to access files in this drive."}
              >
                <.icon name="hero-x-mark" class="h-4 w-4" />
              </button>
            </div>
          </div>
        </div>

        <button
          :if={!@personal_connected}
          type="button"
          class="sa-btn secondary sa-drive-connect-personal"
          phx-click="connect_personal_drive"
        >
          <.icon name="hero-folder" class="h-4 w-4" />
          Connect My Drive
        </button>

        <div :if={@available_not_connected != []} class="sa-drive-available">
          <h4>Available Shared Drives</h4>
          <p class="sa-muted">Shared drives discovered from Google that are not yet connected.</p>
          <div class="sa-drive-list">
            <div
              :for={drive <- @available_not_connected}
              class="sa-drive-row"
            >
              <div class="sa-drive-info">
                <.icon name="hero-circle-stack" class="h-5 w-5 sa-drive-icon" />
                <span class="sa-drive-name">{drive.name}</span>
              </div>
              <button
                type="button"
                class="sa-btn secondary"
                phx-click="connect_drive"
                phx-value-drive_id={drive.id}
                phx-value-name={drive.name}
              >
                Connect
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp has_personal_drive?(drives) do
    Enum.any?(drives, &(&1.drive_type == "personal"))
  end

  defp filter_unconnected(available, connected) do
    connected_ids = MapSet.new(connected, & &1.drive_id)
    Enum.reject(available, fn d -> MapSet.member?(connected_ids, d.id) end)
  end

  defp drive_icon("personal"), do: "hero-folder"
  defp drive_icon("shared"), do: "hero-circle-stack"
  defp drive_icon(_), do: "hero-folder"

  defp drive_type_label("personal"), do: "Personal"
  defp drive_type_label("shared"), do: "Shared"
  defp drive_type_label(type), do: type
end

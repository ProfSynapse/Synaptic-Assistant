defmodule AssistantWeb.Components.SyncTargetBrowser do
  @moduledoc false

  use AssistantWeb, :html

  attr :open, :boolean, default: false
  attr :drives, :list, default: []
  attr :selected_drive, :string, default: ""
  attr :folders, :list, default: []
  attr :loading, :boolean, default: false
  attr :error, :string, default: nil

  def sync_target_browser(assigns) do
    drive_options = Enum.map(assigns.drives, &{&1.label, &1.value})

    assigns =
      assigns
      |> assign(:drive_options, drive_options)
      |> assign(
        :browser_form,
        to_form(%{"drive_id" => assigns.selected_drive || ""}, as: :sync_target_browser)
      )

    ~H"""
    <.modal
      :if={@open}
      id="sync-target-browser-modal"
      title="Add Sync Target"
      max_width="xl"
      on_cancel={Phoenix.LiveView.JS.push("close_sync_target_browser")}
    >
      <.form
        for={@browser_form}
        id="sync-target-drive-form"
        phx-change="change_sync_target_drive"
      >
        <.input
          type="select"
          field={@browser_form[:drive_id]}
          label="Drive"
          options={@drive_options}
        />
      </.form>

      <div :if={@error} class="sa-empty" style="margin-top: 0.75rem;">
        {@error}
      </div>

      <div :if={@loading} class="sa-empty" style="margin-top: 0.75rem;">
        Loading folders...
      </div>

      <div :if={!@loading and @folders == [] and is_nil(@error)} class="sa-empty" style="margin-top: 0.75rem;">
        No folders found for this drive.
      </div>

      <table :if={!@loading and @folders != []} class="sa-table" style="margin-top: 0.75rem;">
        <thead>
          <tr>
            <th>Folder</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={folder <- @folders}>
            <td>{folder.name}</td>
            <td>
              <button
                type="button"
                class="sa-btn"
                phx-click="add_sync_target"
                phx-value-drive_id={@selected_drive}
                phx-value-folder_id={folder.id}
                phx-value-folder_name={folder.name}
              >
                Add
              </button>
            </td>
          </tr>
        </tbody>
      </table>

      <div class="sa-row" style="margin-top: 0.75rem;">
        <button type="button" class="sa-btn secondary" phx-click="close_sync_target_browser">
          Cancel
        </button>
      </div>
    </.modal>
    """
  end
end

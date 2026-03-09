defmodule AssistantWeb.Components.GoogleWorkspaceDriveAccess do
  @moduledoc false

  use AssistantWeb, :html

  attr :connected_drives, :list, default: []
  attr :available_drives, :list, default: []
  attr :drives_loading, :boolean, default: false
  attr :has_google_token, :boolean, default: false
  attr :sync_scopes, :list, default: []
  attr :manager_drive, :map, default: nil
  attr :manager_scopes, :list, default: []
  attr :tree_nodes, :map, default: %{}
  attr :tree_root_keys, :list, default: []
  attr :tree_expanded, :any, default: MapSet.new()
  attr :tree_loading, :boolean, default: false
  attr :tree_loading_nodes, :any, default: MapSet.new()
  attr :tree_error, :string, default: nil
  attr :drive_scope_dirty, :boolean, default: false

  def google_workspace_drive_access(assigns) do
    rows = drive_rows(assigns.connected_drives, assigns.available_drives)
    manager_scope_index = scope_index(assigns.manager_scopes)

    assigns =
      assigns
      |> assign(:rows, rows)
      |> assign(
        :tree_rows,
        visible_tree_rows(
          assigns.tree_root_keys,
          assigns.tree_nodes,
          assigns.tree_expanded,
          manager_scope_index,
          assigns.manager_drive && assigns.manager_drive.drive_id,
          false
        )
      )

    ~H"""
    <section class="sa-google-drive-access">
      <div class="sa-drive-access-header">
        <div class="sa-drive-access-heading">
          <h2>Drive Access</h2>
          <p class="sa-muted">
            Turn on full-drive sync for the common case, or open a drive to scope access down to folders and files.
          </p>
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
        <span>Connect your Google account before managing Drive access.</span>
      </div>

      <div :if={@has_google_token and @rows == [] and !@drives_loading} class="sa-drive-notice sa-drive-notice--info">
        <.icon name="hero-information-circle" class="h-5 w-5" />
        <span>No drives available yet. Refresh drives to discover shared drives.</span>
      </div>

      <div :if={@has_google_token and @rows != []} class="sa-drive-table-shell">
        <table class="sa-table sa-drive-table">
          <thead>
            <tr>
              <th>Drive</th>
              <th>Scope</th>
              <th>Full Access</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @rows}
              class={[
                "sa-drive-table-row",
                @manager_drive && @manager_drive.drive_key == row.drive_key && "sa-drive-table-row-active"
              ]}
            >
              <td>
                <div class="sa-drive-row-title">
                  <span class="sa-drive-row-avatar">
                    <.icon name={drive_icon(row.drive_type)} class="h-5 w-5 sa-drive-icon" />
                  </span>
                  <div class="sa-drive-row-copy">
                    <div class="sa-drive-name">{row.drive_name}</div>
                    <div class="sa-drive-type">{drive_type_label(row.drive_type)}</div>
                  </div>
                </div>
              </td>
              <td>
                <span class={["sa-drive-scope-summary", scope_summary_class(row, @sync_scopes)]}>
                  {scope_summary(row, @sync_scopes)}
                </span>
              </td>
              <td>
                <label class="sa-switch">
                  <input
                    type="checkbox"
                    checked={row.enabled}
                    class="sa-switch-input"
                    role="switch"
                    aria-checked={to_string(row.enabled)}
                    aria-label={"Toggle full access for #{row.drive_name}"}
                    phx-click="toggle_drive"
                    phx-value-id={row.connected_id}
                    phx-value-drive_id={row.drive_id || ""}
                    phx-value-drive_name={row.drive_name}
                    phx-value-drive_type={row.drive_type}
                    phx-value-enabled={to_string(!row.enabled)}
                  />
                  <span class="sa-switch-slider"></span>
                </label>
              </td>
              <td>
                <button
                  type="button"
                  class="sa-icon-btn sa-drive-manage-btn"
                  title={"Manage #{row.drive_name}"}
                  aria-label={"Manage #{row.drive_name}"}
                  phx-click="open_drive_scope_manager"
                  phx-value-id={row.connected_id}
                  phx-value-drive_id={row.drive_id || ""}
                  phx-value-drive_name={row.drive_name}
                  phx-value-drive_type={row.drive_type}
                >
                  <.icon name="hero-cog-6-tooth" class="h-4 w-4" />
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.modal
        :if={@manager_drive}
        id="drive-scope-manager-modal"
        title={"Manage " <> @manager_drive.drive_name}
        max_width="full"
        class="sa-drive-manager-modal"
        on_cancel={Phoenix.LiveView.JS.push("close_drive_scope_manager")}
      >
        <div class="sa-drive-manager">
          <div class="sa-drive-manager-scroll">
            <div class="sa-drive-manager-intro">
              <div>
                <p class="sa-drive-manager-kicker">Scoped Drive Access</p>
                <p class="sa-muted">
                  Select the folders and files to sync into the agent workspace. Folder selections cascade until you override a child.
                </p>
              </div>
              <span class={["sa-drive-scope-summary", scope_summary_class(@manager_drive, @manager_scopes)]}>
                {scope_summary(@manager_drive, @manager_scopes)}
              </span>
            </div>

            <div
              :if={@manager_drive.enabled}
              class="sa-drive-notice sa-drive-notice--info"
            >
              <.icon name="hero-information-circle" class="h-5 w-5" />
              <span>Full access is on for this drive. Turn it off to scope down to folders and files.</span>
            </div>

            <div :if={!@manager_drive.enabled} class="sa-drive-manager-body">
              <div :if={@tree_error} class="sa-drive-notice">
                <.icon name="hero-exclamation-triangle" class="h-5 w-5" />
                <span>{@tree_error}</span>
              </div>

              <div :if={@tree_loading} class="sa-empty sa-drive-manager-state">
                Loading drive contents...
              </div>

              <div
                :if={!@tree_loading and @tree_rows == [] and is_nil(@tree_error)}
                class="sa-empty sa-drive-manager-state"
              >
                No folders or files found at the root of this drive.
              </div>

              <div
                :if={!@tree_loading and @tree_rows != []}
                class="sa-drive-tree"
              >
                <div
                  :for={row <- @tree_rows}
                  class={tree_row_classes(row)}
                  style={tree_row_style(row.depth)}
                >
                  <button
                    type="button"
                    class="sa-drive-tree-check"
                    phx-click="toggle_drive_tree_node_scope"
                    phx-value-node_key={row.node.key}
                    phx-value-node_type={row.node.node_type}
                    aria-label={"Toggle #{row.node.name}"}
                  >
                    <span class="sa-drive-tree-check-shell">
                      <input
                        type="checkbox"
                        checked={row.checkbox_state == :checked}
                        aria-checked={checkbox_aria_state(row.checkbox_state)}
                        tabindex="-1"
                        class="sa-drive-tree-native-check"
                        readonly
                      />
                      <span class={["sa-drive-tree-check-box", "is-#{row.checkbox_state}"]}>
                        <.icon
                          :if={row.checkbox_state == :checked}
                          name="hero-check-solid"
                          class="h-3.5 w-3.5"
                        />
                        <.icon
                          :if={row.checkbox_state == :partial}
                          name="hero-minus"
                          class="h-3.5 w-3.5"
                        />
                      </span>
                    </span>
                  </button>

                  <button
                    :if={row.node.node_type == "folder"}
                    type="button"
                    class="sa-drive-tree-node-trigger"
                    phx-click="toggle_drive_tree_node_expanded"
                    phx-value-node_key={row.node.key}
                    aria-label={if row.expanded?, do: "Collapse #{row.node.name}", else: "Expand #{row.node.name}"}
                  >
                    <span class={["sa-drive-tree-node-avatar", node_avatar_class(row.node)]}>
                      <.icon
                        name={node_icon(row.node, row.expanded?)}
                        class="h-4 w-4 sa-drive-tree-node-icon"
                      />
                    </span>
                    <span class="sa-drive-tree-label-wrap">
                      <span class="sa-drive-tree-label">{row.node.name}</span>
                      <span class="sa-drive-tree-subtitle">Folder</span>
                    </span>
                    <span class="sa-drive-tree-tail">
                      <span
                        :if={MapSet.member?(@tree_loading_nodes, row.node.key)}
                        class="sa-drive-tree-meta"
                      >
                        Loading...
                      </span>
                      <span :if={row.explicit_effect} class="sa-drive-tree-meta">
                        {String.capitalize(row.explicit_effect)}
                      </span>
                    </span>
                  </button>

                  <div :if={row.node.node_type != "folder"} class="sa-drive-tree-node-trigger is-file">
                    <span class={["sa-drive-tree-node-avatar", node_avatar_class(row.node)]}>
                      <.icon
                        name={node_icon(row.node, row.expanded?)}
                        class="h-4 w-4 sa-drive-tree-node-icon"
                      />
                    </span>
                    <span class="sa-drive-tree-label-wrap">
                      <span class="sa-drive-tree-label">{row.node.name}</span>
                    </span>
                    <span class="sa-drive-tree-tail">
                      <span class={["sa-drive-file-badge", file_badge_class(row.node.file_kind)]}>
                        {file_badge_label(row.node.file_kind)}
                      </span>
                      <span :if={row.explicit_effect} class="sa-drive-tree-meta">
                        {String.capitalize(row.explicit_effect)}
                      </span>
                    </span>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div class="sa-drive-manager-footer">
            <span class="sa-drive-manager-dirty">
              {if @drive_scope_dirty, do: "Unsaved changes", else: "No changes yet"}
            </span>
            <div class="sa-drive-manager-actions">
              <button
                type="button"
                class="sa-btn secondary"
                phx-click="close_drive_scope_manager"
              >
                Cancel
              </button>
              <button
                type="button"
                class="sa-btn"
                phx-click="save_drive_scope_manager"
                disabled={!@drive_scope_dirty or @manager_drive.enabled}
              >
                Save Access
              </button>
            </div>
          </div>
        </div>
      </.modal>
    </section>
    """
  end

  defp drive_rows(connected_drives, available_drives) do
    connected_by_id =
      Map.new(connected_drives, &{drive_match_key(&1.drive_type, &1.drive_id), &1})

    available_by_id = Map.new(available_drives, &{drive_match_key("shared", &1.id), &1})

    personal_row =
      build_drive_row(
        Map.get(connected_by_id, drive_match_key("personal", nil)),
        %{id: nil, name: "My Drive"},
        "personal"
      )

    shared_rows =
      connected_by_id
      |> Map.keys()
      |> Enum.reject(&(&1 == drive_match_key("personal", nil)))
      |> Kernel.++(Map.keys(available_by_id))
      |> Enum.uniq()
      |> Enum.map(fn key ->
        connected = Map.get(connected_by_id, key)
        available = Map.get(available_by_id, key)
        build_drive_row(connected, available, "shared")
      end)
      |> Enum.sort_by(&String.downcase(&1.drive_name || ""))

    [personal_row | shared_rows]
  end

  defp build_drive_row(connected, available, drive_type) do
    drive_id = (connected && connected.drive_id) || (available && available.id)

    drive_name =
      (connected && connected.drive_name) || (available && available.name) || "Unknown Drive"

    %{
      drive_key: drive_match_key(drive_type, drive_id),
      drive_id: drive_id,
      drive_name: drive_name,
      drive_type: drive_type,
      connected_id: connected && connected.id,
      connected?: not is_nil(connected),
      enabled: (connected && connected.enabled) || false
    }
  end

  defp drive_match_key("personal", _drive_id), do: "personal"
  defp drive_match_key(_drive_type, drive_id), do: "drive:" <> to_string(drive_id)

  defp scope_index(scopes) do
    Enum.reduce(scopes, %{drive: %{}, folder: %{}, file: %{}}, fn scope, acc ->
      case scope.scope_type do
        "drive" -> put_in(acc, [:drive, scope.drive_id], scope)
        "folder" -> put_in(acc, [:folder, {scope.drive_id, scope.folder_id}], scope)
        "file" -> put_in(acc, [:file, {scope.drive_id, scope.file_id}], scope)
        _ -> acc
      end
    end)
  end

  defp visible_tree_rows(root_keys, nodes, expanded, scope_index, drive_id, inherited_selected?) do
    Enum.flat_map(root_keys, fn key ->
      node = Map.fetch!(nodes, key)

      build_visible_tree_rows(
        node,
        nodes,
        expanded,
        scope_index,
        drive_id,
        inherited_selected?,
        0
      )
    end)
  end

  defp build_visible_tree_rows(
         node,
         nodes,
         expanded,
         scope_index,
         drive_id,
         inherited_selected?,
         depth
       ) do
    explicit_effect = explicit_effect(node, scope_index, drive_id)
    effective_selected? = explicit_selected?(explicit_effect, inherited_selected?)
    expanded? = node.node_type == "folder" and MapSet.member?(expanded, node.key)
    children = Enum.map(node.child_keys || [], &Map.fetch!(nodes, &1))

    child_rows =
      if expanded? do
        Enum.flat_map(children, fn child ->
          build_visible_tree_rows(
            child,
            nodes,
            expanded,
            scope_index,
            drive_id,
            effective_selected?,
            depth + 1
          )
        end)
      else
        []
      end

    checkbox_state =
      folder_checkbox_state(
        node,
        children,
        nodes,
        expanded,
        scope_index,
        drive_id,
        effective_selected?
      )

    [
      %{
        node: node,
        depth: depth,
        checkbox_state: checkbox_state,
        expanded?: expanded?,
        explicit_effect: explicit_effect
      }
      | child_rows
    ]
  end

  defp folder_checkbox_state(
         %{node_type: "file"},
         _children,
         _nodes,
         _expanded,
         _scope_index,
         _drive_id,
         effective_selected?
       ) do
    if effective_selected?, do: :checked, else: :unchecked
  end

  defp folder_checkbox_state(
         _node,
         children,
         nodes,
         _expanded,
         scope_index,
         drive_id,
         effective_selected?
       ) do
    if children == [] do
      if effective_selected?, do: :checked, else: :unchecked
    else
      child_states =
        Enum.map(children, fn child ->
          child_effect =
            explicit_selected?(explicit_effect(child, scope_index, drive_id), effective_selected?)

          folder_checkbox_state(
            child,
            Enum.map(child.child_keys || [], &Map.fetch!(nodes, &1)),
            nodes,
            nil,
            scope_index,
            drive_id,
            child_effect
          )
        end)

      cond do
        Enum.all?(child_states, &(&1 == :checked)) and effective_selected? -> :checked
        Enum.all?(child_states, &(&1 == :unchecked)) and !effective_selected? -> :unchecked
        true -> :partial
      end
    end
  end

  defp explicit_effect(%{node_type: "folder", id: folder_id}, scope_index, drive_id) do
    case Map.get(scope_index.folder, {drive_id, folder_id}) do
      nil -> nil
      scope -> scope.scope_effect
    end
  end

  defp explicit_effect(%{node_type: "file", id: file_id}, scope_index, drive_id) do
    case Map.get(scope_index.file, {drive_id, file_id}) do
      nil -> nil
      scope -> scope.scope_effect
    end
  end

  defp explicit_selected?("include", _inherited_selected?), do: true
  defp explicit_selected?("exclude", _inherited_selected?), do: false
  defp explicit_selected?(nil, inherited_selected?), do: inherited_selected?

  defp scope_summary(row, scopes) do
    drive_scopes =
      Enum.filter(scopes, fn scope ->
        scope.drive_id == row.drive_id and scope.scope_type in ["folder", "file"]
      end)

    cond do
      row.enabled ->
        "All content"

      drive_scopes == [] ->
        "No scoped content"

      true ->
        "#{length(drive_scopes)} scoped item#{if length(drive_scopes) == 1, do: "", else: "s"}"
    end
  end

  defp scope_summary_class(row, scopes) do
    drive_scopes =
      Enum.filter(scopes, fn scope ->
        scope.drive_id == row.drive_id and scope.scope_type in ["folder", "file"]
      end)

    cond do
      row.enabled -> "is-full"
      drive_scopes == [] -> "is-empty"
      true -> "is-scoped"
    end
  end

  defp drive_icon("shared"), do: "hero-circle-stack"
  defp drive_icon(_), do: "hero-folder"

  defp drive_type_label("shared"), do: "Shared Drive"
  defp drive_type_label(_), do: "My Drive"

  defp tree_row_style(depth), do: "--sa-drive-depth: #{depth};"

  defp tree_row_classes(row) do
    [
      "sa-drive-tree-row",
      row.node.node_type == "folder" && "is-folder",
      row.node.node_type != "folder" && "is-file",
      row.depth == 0 && "is-root",
      row.expanded? && "is-expanded",
      row.checkbox_state == :checked && "is-selected",
      row.checkbox_state == :partial && "is-partial"
    ]
  end

  defp checkbox_aria_state(:partial), do: "mixed"
  defp checkbox_aria_state(:checked), do: "true"
  defp checkbox_aria_state(_), do: "false"

  defp node_icon(%{node_type: "folder"}, true), do: "hero-folder"
  defp node_icon(%{node_type: "folder"}, false), do: "hero-folder"
  defp node_icon(%{file_kind: "doc"}, _expanded?), do: "hero-document-text"
  defp node_icon(%{file_kind: "sheet"}, _expanded?), do: "hero-document-chart-bar"
  defp node_icon(%{file_kind: "slides"}, _expanded?), do: "hero-clipboard-document-list"
  defp node_icon(%{file_kind: "pdf"}, _expanded?), do: "hero-document-check"
  defp node_icon(%{file_kind: "image"}, _expanded?), do: "hero-photo"
  defp node_icon(_node, _expanded?), do: "hero-document-duplicate"

  defp node_avatar_class(%{node_type: "folder"}), do: "is-folder"
  defp node_avatar_class(%{file_kind: "doc"}), do: "is-doc"
  defp node_avatar_class(%{file_kind: "sheet"}), do: "is-sheet"
  defp node_avatar_class(%{file_kind: "slides"}), do: "is-slides"
  defp node_avatar_class(%{file_kind: "pdf"}), do: "is-pdf"
  defp node_avatar_class(%{file_kind: "image"}), do: "is-image"
  defp node_avatar_class(_node), do: "is-file"

  defp file_badge_class("doc"), do: "is-doc"
  defp file_badge_class("sheet"), do: "is-sheet"
  defp file_badge_class("slides"), do: "is-slides"
  defp file_badge_class("pdf"), do: "is-pdf"
  defp file_badge_class("image"), do: "is-image"
  defp file_badge_class(_), do: "is-file"

  defp file_badge_label("doc"), do: "DOC"
  defp file_badge_label("sheet"), do: "SHEET"
  defp file_badge_label("slides"), do: "SLIDES"
  defp file_badge_label("pdf"), do: "PDF"
  defp file_badge_label("image"), do: "IMG"
  defp file_badge_label(_), do: "FILE"

end

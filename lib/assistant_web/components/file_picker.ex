defmodule AssistantWeb.Components.FilePicker do
  @moduledoc false

  use AssistantWeb, :html

  attr :title, :string, default: "Storage Access"
  attr :description, :string, default: "Manage accessible storage sources and scoped content."
  attr :connected_sources, :list, default: []
  attr :available_sources, :list, default: []
  attr :sources_loading, :boolean, default: false
  attr :provider_connected, :boolean, default: false
  attr :saved_scopes, :list, default: []
  attr :selected_source, :map, default: nil
  attr :draft_scopes, :list, default: []
  attr :nodes, :map, default: %{}
  attr :root_keys, :list, default: []
  attr :expanded, :any, default: MapSet.new()
  attr :loading, :boolean, default: false
  attr :loading_nodes, :any, default: MapSet.new()
  attr :error, :string, default: nil
  attr :dirty, :boolean, default: false
  attr :disabled_notice, :string, default: nil

  def storage_source_access(assigns) do
    rows = source_rows(assigns.connected_sources, assigns.available_sources)
    draft_scope_index = scope_index(assigns.draft_scopes)

    assigns =
      assigns
      |> assign(:rows, rows)
      |> assign(
        :tree_rows,
        visible_tree_rows(
          assigns.root_keys,
          assigns.nodes,
          assigns.expanded,
          draft_scope_index,
          assigns.selected_source && assigns.selected_source.source_id,
          false
        )
      )

    ~H"""
    <section class="sa-google-drive-access">
      <div class="sa-drive-access-header">
        <div class="sa-drive-access-heading">
          <h2>{@title}</h2>
          <p class="sa-muted">{@description}</p>
        </div>
        <button
          :if={@provider_connected}
          type="button"
          class="sa-btn secondary"
          phx-click="refresh_storage_sources"
          disabled={@sources_loading}
        >
          <.icon name="hero-arrow-path" class={["h-4 w-4", @sources_loading && "sa-spin"]} />
          {if @sources_loading, do: "Refreshing...", else: "Refresh Sources"}
        </button>
      </div>

      <div :if={!@provider_connected} class="sa-drive-notice">
        <.icon name="hero-exclamation-triangle" class="h-5 w-5" />
        <span>{@disabled_notice || "Connect this provider before managing storage access."}</span>
      </div>

      <div
        :if={@provider_connected and @rows == [] and !@sources_loading}
        class="sa-drive-notice sa-drive-notice--info"
      >
        <.icon name="hero-information-circle" class="h-5 w-5" />
        <span>No sources available yet. Refresh to discover available roots.</span>
      </div>

      <div :if={@provider_connected and @rows != []} class="sa-drive-table-shell">
        <table class="sa-table sa-drive-table">
          <thead>
            <tr>
              <th>Source</th>
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
                @selected_source && @selected_source.source_key == row.source_key && "sa-drive-table-row-active"
              ]}
            >
              <td>
                <div class="sa-drive-row-title">
                  <span class="sa-drive-row-avatar">
                    <.icon name={source_icon(row.source_type)} class="h-5 w-5 sa-drive-icon" />
                  </span>
                  <div class="sa-drive-row-copy">
                    <div class="sa-drive-name">{row.source_name}</div>
                    <div class="sa-drive-type">{source_type_label(row.source_type)}</div>
                  </div>
                </div>
              </td>
              <td>
                <span class={["sa-drive-scope-summary", scope_summary_class(row, @saved_scopes)]}>
                  {scope_summary(row, @saved_scopes)}
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
                    aria-label={"Toggle full access for #{row.source_name}"}
                    phx-click="toggle_storage_source_access"
                    phx-value-id={row.connected_id}
                    phx-value-source_id={row.source_id}
                    phx-value-source_name={row.source_name}
                    phx-value-source_type={row.source_type}
                    phx-value-enabled={to_string(!row.enabled)}
                  />
                  <span class="sa-switch-slider"></span>
                </label>
              </td>
              <td>
                <button
                  type="button"
                  class="sa-icon-btn sa-drive-manage-btn"
                  title={"Manage #{row.source_name}"}
                  aria-label={"Manage #{row.source_name}"}
                  phx-click="open_file_picker"
                  phx-value-id={row.connected_id}
                  phx-value-source_id={row.source_id}
                  phx-value-source_name={row.source_name}
                  phx-value-source_type={row.source_type}
                >
                  <.icon name="hero-cog-6-tooth" class="h-4 w-4" />
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.modal
        :if={@selected_source}
        id="file-picker-modal"
        title={"Manage " <> @selected_source.source_name}
        max_width="full"
        class="sa-drive-manager-modal"
        on_cancel={Phoenix.LiveView.JS.push("close_file_picker")}
      >
        <div class="sa-drive-manager">
          <div class="sa-drive-manager-scroll">
            <div class="sa-drive-manager-intro">
              <div>
                <p class="sa-drive-manager-kicker">Scoped Access</p>
                <p class="sa-muted">
                  Select the folders and files to sync into the agent workspace. Folder selections cascade until you override a child.
                </p>
              </div>
              <span class={["sa-drive-scope-summary", scope_summary_class(@selected_source, @draft_scopes)]}>
                {scope_summary(@selected_source, @draft_scopes)}
              </span>
            </div>

            <div :if={@selected_source.enabled} class="sa-drive-notice sa-drive-notice--info">
              <.icon name="hero-information-circle" class="h-5 w-5" />
              <span>Full access is on for this source. Turn it off to scope down to folders and files.</span>
            </div>

            <div :if={!@selected_source.enabled} class="sa-drive-manager-body">
              <div :if={@error} class="sa-drive-notice">
                <.icon name="hero-exclamation-triangle" class="h-5 w-5" />
                <span>{@error}</span>
              </div>

              <div :if={@loading} class="sa-empty sa-drive-manager-state">
                Loading source contents...
              </div>

              <div :if={!@loading and @tree_rows == [] and is_nil(@error)} class="sa-empty sa-drive-manager-state">
                No folders or files found at the root of this source.
              </div>

              <div :if={!@loading and @tree_rows != []} class="sa-drive-tree">
                <div :for={row <- @tree_rows} class={tree_row_classes(row)} style={tree_row_style(row.depth)}>
                  <button
                    type="button"
                    class="sa-drive-tree-check"
                    phx-click="toggle_file_picker_node"
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
                        <.icon :if={row.checkbox_state == :checked} name="hero-check-solid" class="h-3.5 w-3.5" />
                        <.icon :if={row.checkbox_state == :partial} name="hero-minus" class="h-3.5 w-3.5" />
                      </span>
                    </span>
                  </button>

                  <button
                    :if={row.node.node_type == "container"}
                    type="button"
                    class="sa-drive-tree-node-trigger"
                    phx-click="expand_file_picker_node"
                    phx-value-node_key={row.node.key}
                    aria-label={if row.expanded?, do: "Collapse #{row.node.name}", else: "Expand #{row.node.name}"}
                  >
                    <span class={["sa-drive-tree-node-avatar", node_avatar_class(row.node)]}>
                      <.icon name={node_icon(row.node)} class="h-4 w-4 sa-drive-tree-node-icon" />
                    </span>
                    <span class="sa-drive-tree-label-wrap">
                      <span class="sa-drive-tree-label">{row.node.name}</span>
                      <span class="sa-drive-tree-subtitle">Folder</span>
                    </span>
                    <span class="sa-drive-tree-tail">
                      <span :if={MapSet.member?(@loading_nodes, row.node.key)} class="sa-drive-tree-meta">
                        Loading...
                      </span>
                      <span :if={row.explicit_effect} class="sa-drive-tree-meta">
                        {String.capitalize(row.explicit_effect)}
                      </span>
                    </span>
                  </button>

                  <div :if={row.node.node_type != "container"} class="sa-drive-tree-node-trigger is-file">
                    <span class={["sa-drive-tree-node-avatar", node_avatar_class(row.node)]}>
                      <.icon name={node_icon(row.node)} class="h-4 w-4 sa-drive-tree-node-icon" />
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
              {if @dirty, do: "Unsaved changes", else: "No changes yet"}
            </span>
            <div class="sa-drive-manager-actions">
              <button type="button" class="sa-btn secondary" phx-click="close_file_picker">
                Cancel
              </button>
              <button type="button" class="sa-btn" phx-click="save_file_picker" disabled={!@dirty or @selected_source.enabled}>
                Save Access
              </button>
            </div>
          </div>
        </div>
      </.modal>
    </section>
    """
  end

  defp source_rows(connected_sources, available_sources) do
    connected_by_id =
      Map.new(connected_sources, &{source_match_key(&1.source_type, &1.source_id), &1})

    available_by_id =
      Map.new(available_sources, &{source_match_key(&1.source_type, &1.source_id), &1})

    source_keys =
      connected_by_id
      |> Map.keys()
      |> Kernel.++(Map.keys(available_by_id))
      |> Enum.uniq()

    source_keys
    |> Enum.map(fn key ->
      connected = Map.get(connected_by_id, key)
      available = Map.get(available_by_id, key)

      source_type =
        (connected && connected.source_type) || (available && available.source_type) || "root"

      build_source_row(connected, available, source_type)
    end)
    |> Enum.sort_by(fn row ->
      {if(row.source_type == "personal", do: 0, else: 1), String.downcase(row.source_name || "")}
    end)
  end

  defp build_source_row(connected, available, source_type) do
    source_id = (connected && connected.source_id) || (available && available.source_id)

    source_name =
      (connected && connected.source_name) || (available && available.label) || "Unknown Source"

    %{
      source_key: source_match_key(source_type, source_id),
      source_id: source_id,
      source_name: source_name,
      source_type: source_type,
      connected_id: connected && connected.id,
      enabled: (connected && connected.enabled) || false
    }
  end

  defp source_match_key("personal", _source_id), do: "personal"
  defp source_match_key(_source_type, source_id), do: "source:" <> to_string(source_id)

  defp scope_index(scopes) do
    Enum.reduce(scopes, %{source: %{}, container: %{}, file: %{}}, fn scope, acc ->
      case scope.scope_type do
        "source" -> put_in(acc, [:source, scope.source_id], scope)
        "container" -> put_in(acc, [:container, {scope.source_id, scope.node_id}], scope)
        "file" -> put_in(acc, [:file, {scope.source_id, scope.node_id}], scope)
        _ -> acc
      end
    end)
  end

  defp visible_tree_rows(root_keys, nodes, expanded, scope_index, source_id, inherited_selected?) do
    Enum.flat_map(root_keys, fn key ->
      node = Map.fetch!(nodes, key)

      build_visible_tree_rows(
        node,
        nodes,
        expanded,
        scope_index,
        source_id,
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
         source_id,
         inherited_selected?,
         depth
       ) do
    explicit_effect = explicit_effect(node, scope_index, source_id)
    effective_selected? = explicit_selected?(explicit_effect, inherited_selected?)
    expanded? = node.node_type == "container" and MapSet.member?(expanded, node.key)
    children = Enum.map(node.child_keys || [], &Map.fetch!(nodes, &1))

    child_rows =
      if expanded? do
        Enum.flat_map(children, fn child ->
          build_visible_tree_rows(
            child,
            nodes,
            expanded,
            scope_index,
            source_id,
            effective_selected?,
            depth + 1
          )
        end)
      else
        []
      end

    checkbox_state =
      folder_checkbox_state(node, children, nodes, scope_index, source_id, effective_selected?)

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
         %{node_type: type},
         _children,
         _nodes,
         _scope_index,
         _source_id,
         effective_selected?
       )
       when type in ["file", "link"] do
    if effective_selected?, do: :checked, else: :unchecked
  end

  defp folder_checkbox_state(_node, children, nodes, scope_index, source_id, effective_selected?) do
    if children == [] do
      if effective_selected?, do: :checked, else: :unchecked
    else
      child_states =
        Enum.map(children, fn child ->
          child_effect =
            explicit_selected?(
              explicit_effect(child, scope_index, source_id),
              effective_selected?
            )

          folder_checkbox_state(
            child,
            Enum.map(child.child_keys || [], &Map.fetch!(nodes, &1)),
            nodes,
            scope_index,
            source_id,
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

  defp explicit_effect(%{node_type: "container", node_id: node_id}, scope_index, source_id) do
    case Map.get(scope_index.container, {source_id, node_id}) do
      nil -> nil
      scope -> scope.scope_effect
    end
  end

  defp explicit_effect(%{node_type: type, node_id: node_id}, scope_index, source_id)
       when type in ["file", "link"] do
    case Map.get(scope_index.file, {source_id, node_id}) do
      nil -> nil
      scope -> scope.scope_effect
    end
  end

  defp explicit_selected?("include", _inherited_selected?), do: true
  defp explicit_selected?("exclude", _inherited_selected?), do: false
  defp explicit_selected?(nil, inherited_selected?), do: inherited_selected?

  defp scope_summary(row, scopes) do
    source_scopes =
      Enum.filter(scopes, fn scope ->
        scope.source_id == row.source_id and scope.scope_type in ["container", "file"]
      end)

    cond do
      row.enabled ->
        "All content"

      source_scopes == [] ->
        "No scoped content"

      true ->
        "#{length(source_scopes)} scoped item#{if length(source_scopes) == 1, do: "", else: "s"}"
    end
  end

  defp scope_summary_class(row, scopes) do
    source_scopes =
      Enum.filter(scopes, fn scope ->
        scope.source_id == row.source_id and scope.scope_type in ["container", "file"]
      end)

    cond do
      row.enabled -> "is-full"
      source_scopes == [] -> "is-empty"
      true -> "is-scoped"
    end
  end

  defp source_icon("shared"), do: "hero-circle-stack"
  defp source_icon("library"), do: "hero-building-library"
  defp source_icon("namespace"), do: "hero-folder"
  defp source_icon(_), do: "hero-folder"

  defp source_type_label("shared"), do: "Shared Drive"
  defp source_type_label("personal"), do: "Personal Drive"
  defp source_type_label("library"), do: "Library"
  defp source_type_label("namespace"), do: "Namespace"
  defp source_type_label("root"), do: "Root"
  defp source_type_label(type), do: Phoenix.Naming.humanize(type)

  defp tree_row_style(depth), do: "--sa-drive-depth: #{depth};"

  defp tree_row_classes(row) do
    [
      "sa-drive-tree-row",
      row.node.node_type == "container" && "is-folder",
      row.node.node_type != "container" && "is-file",
      row.depth == 0 && "is-root",
      row.expanded? && "is-expanded",
      row.checkbox_state == :checked && "is-selected",
      row.checkbox_state == :partial && "is-partial"
    ]
  end

  defp checkbox_aria_state(:partial), do: "mixed"
  defp checkbox_aria_state(:checked), do: "true"
  defp checkbox_aria_state(_), do: "false"

  defp node_icon(%{node_type: "container"}), do: "hero-folder"
  defp node_icon(%{file_kind: "doc"}), do: "hero-document-text"
  defp node_icon(%{file_kind: "sheet"}), do: "hero-document-chart-bar"
  defp node_icon(%{file_kind: "slides"}), do: "hero-clipboard-document-list"
  defp node_icon(%{file_kind: "pdf"}), do: "hero-document-check"
  defp node_icon(%{file_kind: "image"}), do: "hero-photo"
  defp node_icon(%{node_type: "link"}), do: "hero-link"
  defp node_icon(_node), do: "hero-document-duplicate"

  defp node_avatar_class(%{node_type: "container"}), do: "is-folder"
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

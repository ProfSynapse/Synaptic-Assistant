defmodule AssistantWeb.Components.GoogleWorkspaceDriveAccess do
  @moduledoc false

  use AssistantWeb, :html

  alias AssistantWeb.Components.FilePicker

  attr :connected_sources, :list, default: []
  attr :available_sources, :list, default: []
  attr :sources_loading, :boolean, default: false
  attr :provider_connected, :boolean, default: false
  attr :storage_scopes, :list, default: []
  attr :selected_source, :map, default: nil
  attr :draft_scopes, :list, default: []
  attr :nodes, :map, default: %{}
  attr :root_keys, :list, default: []
  attr :expanded, :any, default: MapSet.new()
  attr :loading, :boolean, default: false
  attr :loading_nodes, :any, default: MapSet.new()
  attr :error, :string, default: nil
  attr :dirty, :boolean, default: false

  def google_workspace_drive_access(assigns) do
    ~H"""
    <.storage_source_access
      title="Drive Access"
      description="Turn on full-drive sync for the common case, or open a source to scope access down to folders and files."
      connected_sources={@connected_sources}
      available_sources={@available_sources}
      sources_loading={@sources_loading}
      provider_connected={@provider_connected}
      saved_scopes={@storage_scopes}
      selected_source={@selected_source}
      draft_scopes={@draft_scopes}
      nodes={@nodes}
      root_keys={@root_keys}
      expanded={@expanded}
      loading={@loading}
      loading_nodes={@loading_nodes}
      error={@error}
      dirty={@dirty}
      disabled_notice="Connect your Google account before managing Drive access."
    />
    """
  end

  defdelegate storage_source_access(assigns), to: FilePicker
end

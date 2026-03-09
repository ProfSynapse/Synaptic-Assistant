defmodule Assistant.Storage.Providers.GoogleDrive do
  @moduledoc """
  Google Drive implementation of the storage provider behaviour.
  """

  @behaviour Assistant.Storage.Provider

  alias Assistant.Integrations.Google.Auth, as: GoogleAuth
  alias Assistant.Integrations.Google.Drive
  alias Assistant.Storage.{FileKind, Node, Source}

  @impl true
  def list_sources(user_id, _opts \\ []) do
    with {:ok, access_token} <- GoogleAuth.user_token(user_id),
         {:ok, shared_drives} <- drive_module().list_shared_drives(access_token) do
      {:ok,
       [
         %Source{
           provider: :google_drive,
           source_id: "personal",
           source_type: "personal",
           label: "My Drive",
           capabilities: capabilities()
         }
         | Enum.map(shared_drives, &shared_drive_source/1)
       ]}
    end
  end

  @impl true
  def search_sources(user_id, query, opts \\ []) do
    with {:ok, sources} <- list_sources(user_id, opts) do
      normalized = String.downcase(String.trim(query || ""))

      {:ok,
       Enum.filter(sources, fn source ->
         normalized == "" or String.contains?(String.downcase(source.label), normalized)
       end)}
    end
  end

  @impl true
  def get_source(user_id, source_ref, opts \\ []) do
    with {:ok, sources} <- list_sources(user_id, opts) do
      case Enum.find(sources, &(&1.source_id == source_ref)) do
        nil -> {:error, :not_found}
        source -> {:ok, source}
      end
    end
  end

  @impl true
  def list_children(user_id, %Source{} = source, parent_ref, _opts \\ []) do
    with {:ok, access_token} <- GoogleAuth.user_token(user_id),
         {:ok, items} <-
           drive_module().list_files(
             access_token,
             children_query(source.source_id, parent_ref),
             children_query_opts(source.source_id)
           ) do
      {:ok,
       %{
         items:
           items |> Enum.sort_by(&sort_key/1) |> Enum.map(&normalize_node(source, &1, parent_ref)),
         next_cursor: nil,
         complete?: true
       }}
    end
  end

  @impl true
  def get_delta_cursor(_user_id, _source, _opts \\ []) do
    {:error, :not_implemented}
  end

  @impl true
  def normalize_file_kind(item) do
    FileKind.normalize(
      Map.get(item, :mime_type) || Map.get(item, "mime_type"),
      Map.get(item, :name)
    )
  end

  @impl true
  def capabilities do
    %{
      search_sources: false,
      paginated_children: false,
      supports_links: false
    }
  end

  defp shared_drive_source(drive) do
    %Source{
      provider: :google_drive,
      source_id: drive.id,
      source_type: "shared",
      label: drive.name,
      capabilities: capabilities()
    }
  end

  defp children_query("personal", :root), do: "'root' in parents and trashed=false"
  defp children_query(source_id, :root), do: "'#{source_id}' in parents and trashed=false"
  defp children_query(_source_id, nil), do: "'root' in parents and trashed=false"
  defp children_query(_source_id, parent_id), do: "'#{parent_id}' in parents and trashed=false"

  defp children_query_opts("personal") do
    [
      pageSize: 200,
      orderBy: "name",
      corpora: "user",
      includeItemsFromAllDrives: true,
      supportsAllDrives: true
    ]
  end

  defp children_query_opts(source_id) do
    [
      pageSize: 200,
      orderBy: "name",
      corpora: "drive",
      driveId: source_id,
      includeItemsFromAllDrives: true,
      supportsAllDrives: true
    ]
  end

  defp normalize_node(source, item, parent_ref) do
    mime_type = item.mime_type
    container? = mime_type == "application/vnd.google-apps.folder"

    %Node{
      provider: :google_drive,
      source_id: source.source_id,
      node_id: item.id,
      parent_node_id: parent_node_id(parent_ref),
      name: item.name,
      node_type: if(container?, do: :container, else: :file),
      file_kind: if(container?, do: nil, else: normalize_file_kind(item)),
      mime_type: mime_type,
      provider_metadata: %{parents: item.parents || []}
    }
  end

  defp sort_key(item) do
    folder? = item.mime_type == "application/vnd.google-apps.folder"
    {if(folder?, do: 0, else: 1), String.downcase(item.name || "")}
  end

  defp parent_node_id(:root), do: nil
  defp parent_node_id(nil), do: nil
  defp parent_node_id(parent_id), do: parent_id

  defp drive_module do
    Application.get_env(:assistant, :google_drive_module, Drive)
  end
end

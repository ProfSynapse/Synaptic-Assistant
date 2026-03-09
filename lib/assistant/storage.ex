defmodule Assistant.Storage do
  @moduledoc """
  Provider-neutral storage source and scope context.
  """

  import Ecto.Query

  alias Assistant.Repo
  alias Assistant.Schemas.{ConnectedStorageSource, StorageScope}
  alias Assistant.Storage.Source

  @provider_modules %{
    google_drive: Assistant.Storage.Providers.GoogleDrive
  }

  @source_scope_type "source"
  @container_scope_type "container"
  @file_scope_type "file"

  @spec provider_module(atom() | String.t()) :: module() | nil
  def provider_module(provider) do
    Map.get(@provider_modules, provider_module_key(provider))
  end

  @spec list_provider_sources(binary(), atom() | String.t(), keyword()) ::
          {:ok, [Source.t()]} | {:error, term()}
  def list_provider_sources(user_id, provider, opts \\ []) do
    case provider_module(provider) do
      nil -> {:error, :unsupported_provider}
      module -> module.list_sources(user_id, opts)
    end
  end

  @spec search_provider_sources(binary(), atom() | String.t(), String.t(), keyword()) ::
          {:ok, [Source.t()]} | {:error, term()}
  def search_provider_sources(user_id, provider, query, opts \\ []) do
    case provider_module(provider) do
      nil -> {:error, :unsupported_provider}
      module -> module.search_sources(user_id, query, opts)
    end
  end

  @spec get_provider_source(binary(), atom() | String.t(), String.t(), keyword()) ::
          {:ok, Source.t()} | {:error, term()}
  def get_provider_source(user_id, provider, source_id, opts \\ []) do
    case provider_module(provider) do
      nil -> {:error, :unsupported_provider}
      module -> module.get_source(user_id, source_id, opts)
    end
  end

  @spec list_children(
          binary(),
          atom() | String.t(),
          Source.t(),
          String.t() | :root | nil,
          keyword()
        ) ::
          {:ok, %{items: list(), next_cursor: term() | nil, complete?: boolean()}}
          | {:error, term()}
  def list_children(user_id, provider, %Source{} = source, parent_ref, opts \\ []) do
    case provider_module(provider) do
      nil -> {:error, :unsupported_provider}
      module -> module.list_children(user_id, source, parent_ref, opts)
    end
  end

  @spec provider_capabilities(atom() | String.t()) :: map()
  def provider_capabilities(provider) do
    case provider_module(provider) do
      nil -> %{}
      module -> module.capabilities()
    end
  end

  @spec list_connected_sources(binary(), keyword()) :: [ConnectedStorageSource.t()]
  def list_connected_sources(user_id, opts \\ []) do
    provider = normalize_provider(Keyword.get(opts, :provider))

    ConnectedStorageSource
    |> where([source], source.user_id == ^user_id)
    |> maybe_filter_provider(provider)
    |> maybe_filter_enabled(Keyword.get(opts, :enabled))
    |> order_by([source], asc: source.provider, asc: source.source_type, asc: source.source_name)
    |> Repo.all()
  end

  @spec get_connected_source(binary()) :: ConnectedStorageSource.t() | nil
  def get_connected_source(id), do: Repo.get(ConnectedStorageSource, id)

  @spec get_connected_source(binary(), atom() | String.t(), String.t()) ::
          ConnectedStorageSource.t() | nil
  def get_connected_source(user_id, provider, source_id) do
    provider = normalize_provider(provider)

    ConnectedStorageSource
    |> where(
      [source],
      source.user_id == ^user_id and source.provider == ^provider and
        source.source_id == ^source_id
    )
    |> Repo.one()
  end

  @spec connect_source(binary(), map()) ::
          {:ok, ConnectedStorageSource.t()} | {:error, Ecto.Changeset.t() | term()}
  def connect_source(user_id, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("user_id", user_id)
      |> normalize_source_attrs()

    result =
      %ConnectedStorageSource{}
      |> ConnectedStorageSource.changeset(attrs)
      |> Repo.insert(
        on_conflict:
          {:replace,
           [:source_name, :source_type, :enabled, :capabilities, :provider_metadata, :updated_at]},
        conflict_target: [:user_id, :provider, :source_id],
        returning: true
      )

    result
  end

  @spec toggle_connected_source(binary(), boolean()) ::
          {:ok, ConnectedStorageSource.t()} | {:error, term()}
  def toggle_connected_source(id, enabled?) do
    case Repo.get(ConnectedStorageSource, id) do
      nil ->
        {:error, :not_found}

      source ->
        source |> Ecto.Changeset.change(enabled: enabled?) |> Repo.update()
    end
  end

  @spec disconnect_connected_source(binary()) ::
          {:ok, ConnectedStorageSource.t()} | {:error, term()}
  def disconnect_connected_source(id) do
    case Repo.get(ConnectedStorageSource, id) do
      nil ->
        {:error, :not_found}

      source ->
        Repo.delete(source)
    end
  end

  @spec list_scopes(binary(), keyword()) :: [StorageScope.t()]
  def list_scopes(user_id, opts \\ []) do
    provider = normalize_provider(Keyword.get(opts, :provider))
    source_id = Keyword.get(opts, :source_id)

    StorageScope
    |> where([scope], scope.user_id == ^user_id)
    |> maybe_filter_scope_provider(provider)
    |> maybe_filter_scope_source(source_id)
    |> order_by([scope], asc: scope.scope_type, asc: scope.label)
    |> Repo.all()
  end

  @spec get_scope(binary(), atom() | String.t(), String.t(), String.t() | nil, String.t()) ::
          StorageScope.t() | nil
  def get_scope(user_id, provider, source_id, node_id, scope_type) do
    provider = normalize_provider(provider)

    StorageScope
    |> where(
      [scope],
      scope.user_id == ^user_id and scope.provider == ^provider and scope.source_id == ^source_id and
        scope.scope_type == ^scope_type
    )
    |> maybe_filter_scope_node(node_id)
    |> Repo.one()
  end

  @spec upsert_scope(map()) :: {:ok, StorageScope.t()} | {:error, Ecto.Changeset.t() | term()}
  def upsert_scope(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> normalize_scope_attrs()

    result =
      %StorageScope{}
      |> StorageScope.changeset(attrs)
      |> Repo.insert(
        on_conflict:
          {:replace,
           [
             :parent_node_id,
             :node_type,
             :scope_effect,
             :access_level,
             :label,
             :file_kind,
             :mime_type,
             :provider_metadata,
             :updated_at
           ]},
        conflict_target: conflict_target_for_scope(attrs),
        returning: true
      )

    result
  end

  @spec delete_scope(StorageScope.t()) :: {:ok, StorageScope.t()} | {:error, term()}
  def delete_scope(%StorageScope{} = scope) do
    Repo.delete(scope)
  end

  @spec delete_scopes_in_targets(binary(), atom() | String.t(), String.t(), [String.t()], [
          String.t()
        ]) ::
          {non_neg_integer(), nil}
  def delete_scopes_in_targets(user_id, provider, source_id, container_node_ids, file_node_ids) do
    provider = normalize_provider(provider)

    count =
      StorageScope
      |> where(
        [scope],
        scope.user_id == ^user_id and scope.provider == ^provider and
          scope.source_id == ^source_id
      )
      |> where(
        [scope],
        (scope.scope_type == ^@container_scope_type and
           scope.node_id in ^List.wrap(container_node_ids)) or
          (scope.scope_type == ^@file_scope_type and scope.node_id in ^List.wrap(file_node_ids))
      )
      |> Repo.all()
      |> Enum.reduce(0, fn scope, acc ->
        case delete_scope(scope) do
          {:ok, _} -> acc + 1
          _ -> acc
        end
      end)

    {count, nil}
  end

  @spec provider_source_id(String.t()) :: String.t() | nil
  def provider_source_id("personal"), do: nil
  def provider_source_id(source_id), do: source_id

  @spec source_scope_type() :: String.t()
  def source_scope_type, do: @source_scope_type

  @spec container_scope_type() :: String.t()
  def container_scope_type, do: @container_scope_type

  @spec file_scope_type() :: String.t()
  def file_scope_type, do: @file_scope_type

  defp normalize_provider(nil), do: nil
  defp normalize_provider(provider) when is_atom(provider), do: provider |> Atom.to_string()
  defp normalize_provider(provider), do: provider

  defp provider_module_key(provider) when is_atom(provider), do: provider
  defp provider_module_key("google_drive"), do: :google_drive
  defp provider_module_key("dropbox"), do: :dropbox
  defp provider_module_key("microsoft"), do: :microsoft
  defp provider_module_key("box"), do: :box
  defp provider_module_key(_), do: nil

  defp maybe_filter_provider(query, nil), do: query

  defp maybe_filter_provider(query, provider),
    do: where(query, [source], source.provider == ^provider)

  defp maybe_filter_enabled(query, nil), do: query

  defp maybe_filter_enabled(query, enabled),
    do: where(query, [source], source.enabled == ^enabled)

  defp maybe_filter_scope_provider(query, nil), do: query

  defp maybe_filter_scope_provider(query, provider),
    do: where(query, [scope], scope.provider == ^provider)

  defp maybe_filter_scope_source(query, nil), do: query

  defp maybe_filter_scope_source(query, source_id),
    do: where(query, [scope], scope.source_id == ^source_id)

  defp maybe_filter_scope_node(query, nil), do: where(query, [scope], is_nil(scope.node_id))

  defp maybe_filter_scope_node(query, node_id),
    do: where(query, [scope], scope.node_id == ^node_id)

  defp normalize_source_attrs(attrs) do
    attrs
    |> Map.put("provider", normalize_provider(Map.get(attrs, "provider")))
    |> Map.update("capabilities", %{}, &(&1 || %{}))
    |> Map.update("provider_metadata", %{}, &(&1 || %{}))
  end

  defp normalize_scope_attrs(attrs) do
    attrs
    |> Map.put("provider", normalize_provider(Map.get(attrs, "provider")))
    |> Map.update("provider_metadata", %{}, &(&1 || %{}))
  end

  defp conflict_target_for_scope(%{"node_id" => node_id} = attrs) when node_id in [nil, ""] do
    {:unsafe_fragment,
     ~s|(user_id, provider, source_id, scope_type) WHERE node_id IS NULL AND scope_type = '#{Map.get(attrs, "scope_type")}'|}
  end

  defp conflict_target_for_scope(%{"scope_type" => scope_type}) do
    {:unsafe_fragment,
     ~s|(user_id, provider, source_id, node_id, scope_type) WHERE node_id IS NOT NULL AND scope_type = '#{scope_type}'|}
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end

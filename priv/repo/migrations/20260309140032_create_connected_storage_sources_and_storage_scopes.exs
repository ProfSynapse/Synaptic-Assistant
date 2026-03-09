defmodule Assistant.Repo.Migrations.CreateConnectedStorageSourcesAndStorageScopes do
  use Ecto.Migration

  def change do
    create table(:connected_storage_sources, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :source_id, :string, null: false
      add :source_name, :string, null: false
      add :source_type, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :capabilities, :map, null: false, default: %{}
      add :provider_metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:connected_storage_sources, [:user_id, :provider, :source_id],
             name: :connected_storage_sources_user_provider_source_unique
           )

    create index(:connected_storage_sources, [:user_id, :provider])

    create constraint(:connected_storage_sources, :connected_storage_sources_valid_provider,
             check: "provider IN ('google_drive', 'dropbox', 'microsoft', 'box')"
           )

    create constraint(:connected_storage_sources, :connected_storage_sources_valid_source_type,
             check:
               "source_type IN ('personal', 'shared', 'namespace', 'library', 'root', 'site')"
           )

    create table(:storage_scopes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :source_id, :string, null: false
      add :node_id, :string
      add :parent_node_id, :string
      add :node_type, :string, null: false
      add :scope_type, :string, null: false, default: "container"
      add :scope_effect, :string, null: false, default: "include"
      add :access_level, :string, null: false, default: "read_only"
      add :label, :string, null: false
      add :file_kind, :string
      add :mime_type, :string
      add :provider_metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:storage_scopes, [:user_id, :provider, :source_id, :scope_type],
             name: :storage_scopes_source_unique,
             where: "node_id IS NULL"
           )

    create unique_index(:storage_scopes, [:user_id, :provider, :source_id, :node_id, :scope_type],
             name: :storage_scopes_node_unique,
             where: "node_id IS NOT NULL"
           )

    create index(:storage_scopes, [:user_id, :provider, :source_id])

    create constraint(:storage_scopes, :storage_scopes_valid_provider,
             check: "provider IN ('google_drive', 'dropbox', 'microsoft', 'box')"
           )

    create constraint(:storage_scopes, :storage_scopes_valid_scope_type,
             check: "scope_type IN ('source', 'container', 'file')"
           )

    create constraint(:storage_scopes, :storage_scopes_valid_scope_effect,
             check: "scope_effect IN ('include', 'exclude')"
           )

    create constraint(:storage_scopes, :storage_scopes_valid_access_level,
             check: "access_level IN ('read_only', 'read_write')"
           )

    create constraint(:storage_scopes, :storage_scopes_valid_node_type,
             check: "node_type IN ('source', 'container', 'file', 'link')"
           )
  end
end

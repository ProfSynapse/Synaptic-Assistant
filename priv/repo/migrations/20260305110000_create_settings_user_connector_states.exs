defmodule Assistant.Repo.Migrations.CreateSettingsUserConnectorStates do
  use Ecto.Migration

  def change do
    create table(:settings_user_connector_states, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :integration_group, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :metadata, :map, null: false, default: %{}
      add :connected_at, :utc_datetime_usec
      add :disconnected_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:settings_user_connector_states, [:user_id, :integration_group],
             name: :settings_user_connector_states_user_group_unique
           )

    create index(:settings_user_connector_states, [:user_id])
    create index(:settings_user_connector_states, [:integration_group])
  end
end

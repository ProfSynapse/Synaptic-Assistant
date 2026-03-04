defmodule Assistant.Repo.Migrations.CreateUserIdentities do
  @moduledoc """
  Creates the user_identities table for cross-channel identity mapping.

  Each row maps a (channel, external_id, space_id) tuple to a users row.
  A single user can have multiple identities across different channels.
  """
  use Ecto.Migration

  def change do
    create table(:user_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :channel, :text, null: false
      add :external_id, :text, null: false
      add :space_id, :text
      add :display_name, :text
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # Unique identity per channel + external_id + space_id.
    # COALESCE handles nullable space_id so (telegram, 123, NULL) and
    # (telegram, 123, NULL) correctly conflict.
    create unique_index(:user_identities, ["channel", "external_id", "COALESCE(space_id, '')"],
             name: :user_identities_channel_external_id_space_unique
           )

    create index(:user_identities, [:user_id])
    create index(:user_identities, [:channel, :external_id])
  end
end

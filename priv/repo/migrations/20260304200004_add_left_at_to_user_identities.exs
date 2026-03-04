defmodule Assistant.Repo.Migrations.AddLeftAtToUserIdentities do
  @moduledoc """
  Adds a `left_at` timestamp to user_identities for soft-delete support
  when a user is removed from a GChat Space (REMOVED_FROM_SPACE event).

  The partial index enables efficient lookup of active members in a space
  for the space context fan-out feature.
  """
  use Ecto.Migration

  def change do
    alter table(:user_identities) do
      add :left_at, :utc_datetime_usec
    end

    create index(:user_identities, [:space_id],
      name: :idx_user_identities_space_active,
      where: "left_at IS NULL AND space_id IS NOT NULL"
    )
  end
end

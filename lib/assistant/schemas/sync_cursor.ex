# lib/assistant/schemas/sync_cursor.ex — Per-user per-drive Google Drive Changes API cursor.
#
# Tracks the `startPageToken` for the Drive Changes API so each sync poll
# only fetches files modified since the last poll. One cursor per drive per user,
# following the same partial-index pattern as `connected_drives`.
#
# Related files:
#   - lib/assistant/sync/state_store.ex (CRUD context)
#   - lib/assistant/integrations/google/drive/changes.ex (Changes API wrapper)
#   - priv/repo/migrations/20260302140000_create_sync_cursors.exs (migration)

defmodule Assistant.Schemas.SyncCursor do
  @moduledoc """
  Per-user per-drive cursor for the Google Drive Changes API.

  Stores the `start_page_token` returned by `changes.getStartPageToken` so
  subsequent polls via `changes.list` only return files modified since the
  last sync. The `drive_id` field is nil for the user's personal (My Drive)
  and set to the shared drive ID for shared drives.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sync_cursors" do
    field :drive_id, :string
    field :start_page_token, :string
    field :last_poll_at, :utc_datetime_usec

    belongs_to :user, Assistant.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :start_page_token]
  @optional_fields [:drive_id, :last_poll_at]

  def changeset(cursor, attrs) do
    cursor
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:user_id, :drive_id],
      name: :sync_cursors_user_drive_unique,
      message: "cursor already exists for this drive"
    )
    |> unique_constraint([:user_id],
      name: :sync_cursors_user_personal_unique,
      message: "cursor already exists for personal drive"
    )
  end
end

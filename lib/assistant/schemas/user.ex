defmodule Assistant.Schemas.User do
  @moduledoc """
  User schema. Represents a human user.

  With the unified conversation architecture, the authoritative identity mapping
  lives in `user_identities`. The `external_id` and `channel` fields on this
  table are retained for backward compatibility (existing callers still set them)
  but are no longer required — a user's identity may exist only in
  `user_identities` after cross-channel linking.

  Preferences stored as JSONB for flexibility.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field :external_id, :string
    field :channel, :string
    field :email, :string
    field :display_name, :string
    field :timezone, :string, default: "UTC"
    field :preferences, :map, default: %{}

    has_many :identities, Assistant.Schemas.UserIdentity
    has_many :conversations, Assistant.Schemas.Conversation
    has_many :tasks, Assistant.Schemas.Task, foreign_key: :assignee_id
    has_many :created_tasks, Assistant.Schemas.Task, foreign_key: :creator_id
    has_many :memory_entries, Assistant.Schemas.MemoryEntry
    has_many :memory_entities, Assistant.Schemas.MemoryEntity
    has_many :connected_drives, Assistant.Schemas.ConnectedDrive
    has_many :connected_storage_sources, Assistant.Schemas.ConnectedStorageSource
    has_many :oauth_tokens, Assistant.Schemas.OAuthToken
    has_many :auth_tokens, Assistant.Schemas.AuthToken
    has_many :skill_overrides, Assistant.Schemas.UserSkillOverride
    has_many :connector_states, Assistant.Schemas.SettingsUserConnectorState
    has_many :storage_scopes, Assistant.Schemas.StorageScope

    timestamps(type: :utc_datetime_usec)
  end

  # external_id and channel moved to optional: identity is now authoritative
  # in user_identities. Existing callers still provide these fields — this
  # change only relaxes the validation constraint.
  @required_fields []
  @optional_fields [:external_id, :channel, :email, :display_name, :timezone, :preferences]

  def changeset(user, attrs) do
    user
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end

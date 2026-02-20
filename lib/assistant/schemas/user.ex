defmodule Assistant.Schemas.User do
  @moduledoc """
  User schema. Represents a human user identified by their external ID
  and channel combination. Preferences stored as JSONB for flexibility.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field :external_id, :string
    field :channel, :string
    field :display_name, :string
    field :timezone, :string, default: "UTC"
    field :preferences, :map, default: %{}

    has_many :conversations, Assistant.Schemas.Conversation
    has_many :tasks, Assistant.Schemas.Task, foreign_key: :assignee_id
    has_many :created_tasks, Assistant.Schemas.Task, foreign_key: :creator_id
    has_many :memory_entries, Assistant.Schemas.MemoryEntry
    has_many :memory_entities, Assistant.Schemas.MemoryEntity
    has_many :connected_drives, Assistant.Schemas.ConnectedDrive
    has_many :oauth_tokens, Assistant.Schemas.OAuthToken
    has_many :auth_tokens, Assistant.Schemas.AuthToken

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:external_id, :channel]
  @optional_fields [:display_name, :timezone, :preferences]

  def changeset(user, attrs) do
    user
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:external_id, :channel])
  end
end

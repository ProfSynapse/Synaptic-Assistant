defmodule Assistant.Schemas.UserIdentity do
  @moduledoc """
  Maps a platform identity (channel + external_id + optional space_id) to a
  user. A single user can have multiple identities across different channels,
  enabling cross-channel conversation continuity.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_identities" do
    field :channel, :string
    field :external_id, :string
    field :space_id, :string
    field :display_name, :string
    field :metadata, :map, default: %{}
    field :left_at, :utc_datetime_usec

    belongs_to :user, Assistant.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:channel, :external_id, :user_id]
  @optional_fields [:space_id, :display_name, :metadata, :left_at]

  def changeset(identity, attrs) do
    identity
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:channel, :external_id, :space_id],
      name: :user_identities_channel_external_id_space_unique
    )
  end
end

defmodule Assistant.Schemas.ConnectedStorageSource do
  @moduledoc """
  Persisted user-enabled storage source for a provider.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @providers ~w(google_drive dropbox microsoft box)
  @source_types ~w(personal shared namespace library root site)

  schema "connected_storage_sources" do
    field :provider, :string
    field :source_id, :string
    field :source_name, :string
    field :source_type, :string
    field :enabled, :boolean, default: true
    field :capabilities, :map, default: %{}
    field :provider_metadata, :map, default: %{}

    belongs_to :user, Assistant.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :provider, :source_id, :source_name, :source_type]
  @optional_fields [:enabled, :capabilities, :provider_metadata]

  def changeset(source, attrs) do
    source
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:source_type, @source_types)
    |> unique_constraint([:user_id, :provider, :source_id],
      name: :connected_storage_sources_user_provider_source_unique,
      message: "source already connected"
    )
  end
end

defmodule Assistant.Schemas.DocumentFolder do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "document_folders" do
    field :drive_folder_id, :string
    field :drive_id, :string
    field :name, :string
    field :embedding, Pgvector.Ecto.Vector
    field :activation_boost, :float, default: 1.0
    field :child_count, :integer, default: 0

    belongs_to :user, Assistant.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields ~w(drive_folder_id name user_id)a
  @optional_fields ~w(drive_id embedding activation_boost child_count)a

  def changeset(folder, attrs) do
    folder
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :drive_folder_id])
  end

  @doc """
  Upsert a folder node. Creates if not exists, updates name if it does.
  """
  def upsert(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Assistant.Repo.insert(
      on_conflict: {:replace, [:name, :updated_at]},
      conflict_target: [:user_id, :drive_folder_id],
      returning: true
    )
  end
end

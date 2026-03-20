defmodule Assistant.Schemas.ContentTerm do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "content_terms" do
    field :billing_account_id, :binary_id
    field :owner_type, :string
    field :owner_id, :binary_id
    field :field, :string
    field :term_digest, :string
    field :term_frequency, :integer, default: 1

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(content_term, attrs) do
    content_term
    |> cast(attrs, [
      :billing_account_id,
      :owner_type,
      :owner_id,
      :field,
      :term_digest,
      :term_frequency
    ])
    |> validate_required([
      :billing_account_id,
      :owner_type,
      :owner_id,
      :field,
      :term_digest,
      :term_frequency
    ])
  end
end

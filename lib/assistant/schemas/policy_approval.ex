defmodule Assistant.Schemas.PolicyApproval do
  @moduledoc """
  Persisted approval decisions (pending and historical) for policy-driven actions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @effects ~w(allow ask deny)

  @required_fields [:resource_type, :effect]
  @optional_fields [
    :user_id,
    :workspace_id,
    :rule_id,
    :request_fingerprint,
    :metadata,
    :expires_at
  ]

  schema "policy_approvals" do
    field :user_id, :binary_id
    field :workspace_id, :binary_id
    field :resource_type, :string
    field :effect, :string
    field :request_fingerprint, :string
    field :metadata, :map, default: %{}
    field :expires_at, :utc_datetime_usec

    belongs_to :rule, Assistant.Schemas.PolicyRule

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(approval, attrs) do
    approval
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:effect, @effects)
    |> validate_change(:metadata, &validate_metadata/2)
  end

  defp validate_metadata(:metadata, metadata) when is_map(metadata), do: []
  defp validate_metadata(:metadata, _), do: [metadata: "must be a map"]
end

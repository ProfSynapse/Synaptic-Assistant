defmodule Assistant.Schemas.PolicyRule do
  @moduledoc """
  Determines how the runtime should treat attempted actions.

  A rule is scoped (`system`, `workspace`, or `user`) and matches an action
  descriptor (skill, domain, host, etc.) to yield `allow`, `ask`, or `deny`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @scope_types ~w(system workspace user)
  @effects ~w(allow ask deny)

  @required_fields [:scope_type, :resource_type, :effect]
  @optional_fields [:scope_id, :matchers, :priority, :enabled, :reason, :source]

  schema "policy_rules" do
    field :scope_type, :string, default: "system"
    field :scope_id, :binary_id
    field :resource_type, :string
    field :effect, :string
    field :matchers, :map, default: %{}
    field :priority, :integer, default: 100
    field :enabled, :boolean, default: true
    field :reason, :string
    field :source, :string, default: "system_default"

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:scope_type, @scope_types)
    |> validate_inclusion(:effect, @effects)
    |> validate_number(:priority, greater_than_or_equal_to: 0)
    |> validate_change(:matchers, &validate_matchers/2)
  end

  defp validate_matchers(:matchers, matchers) when is_map(matchers), do: []
  defp validate_matchers(:matchers, _), do: [matchers: "must be a map"]
end

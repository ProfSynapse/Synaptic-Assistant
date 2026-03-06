defmodule Assistant.Schemas.UsageRecord do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "usage_records" do
    field :period_start, :date
    field :period_end, :date
    field :total_cost_cents, :integer, default: 0
    field :total_prompt_tokens, :integer, default: 0
    field :total_completion_tokens, :integer, default: 0
    field :call_count, :integer, default: 0

    belongs_to :settings_user, Assistant.Accounts.SettingsUser

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @required_fields [:settings_user_id, :period_start, :period_end]
  @optional_fields [:total_cost_cents, :total_prompt_tokens, :total_completion_tokens, :call_count]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(usage_record, attrs) do
    usage_record
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:settings_user_id)
    |> unique_constraint([:settings_user_id, :period_start])
  end
end

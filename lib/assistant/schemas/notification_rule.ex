defmodule Assistant.Schemas.NotificationRule do
  @moduledoc """
  Notification rule schema. Routes alerts to channels based on
  severity threshold and optional component filter.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @severities ~w(info warning error critical)

  schema "notification_rules" do
    field :severity_min, :string, default: "error"
    field :component_filter, :string
    field :enabled, :boolean, default: true

    belongs_to :channel, Assistant.Schemas.NotificationChannel

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required_fields [:channel_id]
  @optional_fields [:severity_min, :component_filter, :enabled]

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:severity_min, @severities)
    |> foreign_key_constraint(:channel_id)
  end
end

defmodule Assistant.Schemas.NotificationChannel do
  @moduledoc """
  Notification channel schema. Represents a destination for alerts
  (Google Chat webhook, email, Telegram). Config is stored as encrypted
  binary via Cloak.Ecto.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @channel_types ~w(google_chat_webhook email telegram)

  schema "notification_channels" do
    field :name, :string
    field :type, :string
    field :config, :binary
    field :enabled, :boolean, default: true

    has_many :rules, Assistant.Schemas.NotificationRule, foreign_key: :channel_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required_fields [:name, :type, :config]
  @optional_fields [:enabled]

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:type, @channel_types)
  end
end

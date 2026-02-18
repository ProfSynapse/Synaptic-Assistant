defmodule Assistant.Schemas.NotificationChannel do
  @moduledoc """
  Notification channel schema. Represents a destination for alerts
  (Google Chat webhook, email, Telegram). Config is encrypted at rest
  using Cloak AES-GCM via `Assistant.Encrypted.Binary`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @channel_types ~w(google_chat_webhook email telegram)

  # Webhook URL patterns per channel type, used for SSRF prevention.
  @webhook_url_patterns %{
    "google_chat_webhook" => ~r|^https://chat\.googleapis\.com/|
  }

  schema "notification_channels" do
    field :name, :string
    field :type, :string
    field :config, Assistant.Encrypted.Binary
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
    |> validate_webhook_url()
  end

  # Validates that the config URL matches the expected pattern for the channel type.
  defp validate_webhook_url(changeset) do
    type = get_field(changeset, :type)
    config = get_field(changeset, :config)

    case Map.get(@webhook_url_patterns, type) do
      nil ->
        # No URL pattern defined for this type — skip validation
        changeset

      pattern when is_binary(config) ->
        if Regex.match?(pattern, config) do
          changeset
        else
          add_error(changeset, :config, "must be a valid #{type} webhook URL")
        end

      _pattern ->
        changeset
    end
  end
end

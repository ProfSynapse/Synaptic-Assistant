defmodule Assistant.Schemas.IntegrationSetting do
  @moduledoc """
  Ecto schema for the integration_settings KV table.

  Each row represents one integration key (e.g. :telegram_bot_token).
  The value column is encrypted at rest via Cloak AES-GCM.
  The group column enables UI grouping (e.g. "telegram", "slack").
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Assistant.IntegrationSettings.Registry

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "integration_settings" do
    field :key, :string
    field :value, Assistant.Encrypted.Binary
    field :group, :string

    belongs_to :updated_by, Assistant.Accounts.SettingsUser

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:key, :group]
  @cast_fields [:key, :value, :group, :updated_by_id]

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_known_key()
    |> unique_constraint(:key)
  end

  defp validate_known_key(changeset) do
    case get_field(changeset, :key) do
      nil -> changeset
      key -> if Registry.known_key?(key), do: changeset, else: add_error(changeset, :key, "is not a recognized integration key")
    end
  end
end

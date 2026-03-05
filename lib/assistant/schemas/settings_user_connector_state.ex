defmodule Assistant.Schemas.SettingsUserConnectorState do
  @moduledoc """
  Per-user connector state.

  Tracks whether a connector/integration group is enabled for an individual user.
  Workspace credentials remain admin-managed in IntegrationSettings; this table
  stores each user's on/off state for those integrations.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Assistant.IntegrationSettings.Registry

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @required_fields [:user_id, :integration_group, :enabled]
  @optional_fields [:metadata, :connected_at, :disconnected_at]

  schema "settings_user_connector_states" do
    field :integration_group, :string
    field :enabled, :boolean, default: true
    field :metadata, :map, default: %{}
    field :connected_at, :utc_datetime_usec
    field :disconnected_at, :utc_datetime_usec

    belongs_to :user, Assistant.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(state, attrs) do
    state
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:integration_group, min: 1, max: 120)
    |> validate_change(:integration_group, &validate_known_integration_group/2)
    |> validate_change(:metadata, &validate_metadata/2)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :integration_group],
      name: :settings_user_connector_states_user_group_unique
    )
  end

  defp validate_known_integration_group(:integration_group, group) do
    groups = Registry.groups()

    if is_binary(group) and Map.has_key?(groups, group) do
      []
    else
      [integration_group: "is not a recognized integration group"]
    end
  end

  defp validate_metadata(:metadata, metadata) when is_map(metadata), do: []
  defp validate_metadata(:metadata, _), do: [metadata: "must be a map"]
end

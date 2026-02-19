defmodule Assistant.Schemas.OAuthToken do
  @moduledoc """
  OAuth token schema. Stores per-user OAuth2 credentials (refresh + access tokens)
  for external providers. Tokens are encrypted at rest via Cloak AES-GCM.

  One row per user/provider pair (enforced by unique constraint).
  Currently supports Google; the provider CHECK constraint can be extended
  for future providers (e.g., HubSpot, Microsoft Graph).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_providers ~w(google)

  schema "oauth_tokens" do
    field :provider, :string
    field :provider_uid, :string
    field :provider_email, :string
    field :refresh_token, Assistant.Encrypted.Binary
    field :access_token, Assistant.Encrypted.Binary
    field :token_expires_at, :utc_datetime_usec
    field :scopes, :string

    belongs_to :user, Assistant.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :provider, :refresh_token]
  @optional_fields [:provider_uid, :provider_email, :access_token, :token_expires_at, :scopes]

  def changeset(oauth_token, attrs) do
    oauth_token
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:provider, @valid_providers)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :provider])
  end

  @doc """
  Changeset for updating tokens after a refresh or re-authorization.
  """
  def refresh_changeset(oauth_token, attrs) do
    oauth_token
    |> cast(attrs, [:access_token, :token_expires_at, :refresh_token, :scopes])
    |> validate_required([:access_token])
  end
end

defmodule Assistant.Schemas.OAuthToken do
  @moduledoc """
  Per-user OAuth2 token for external providers (currently Google).

  Refresh and access tokens are encrypted at rest via Cloak AES-GCM.
  One token row per (user, provider) pair. The `provider_email` field
  stores the Google account email for display and first-connect confirmation.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @providers ~w(google)

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

  def changeset(token, attrs) do
    token
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:provider, @providers)
    |> unique_constraint([:user_id, :provider])
  end
end

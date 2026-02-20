defmodule Assistant.Schemas.AuthToken do
  @moduledoc """
  Single-use magic link token for OAuth authorization flows.

  The raw token is never stored — only its SHA-256 hash (`token_hash`).
  Tokens are consumed atomically via `UPDATE ... WHERE used_at IS NULL`.
  The `pending_intent` field is encrypted at rest and stores the original
  user command to be replayed after successful OAuth.
  The `code_verifier` stores the PKCE code_verifier for the OAuth flow.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @purposes ~w(oauth_google)

  schema "auth_tokens" do
    field :token_hash, :string
    field :purpose, :string
    field :code_verifier, :string
    field :oban_job_id, :integer
    field :pending_intent, Assistant.Encrypted.Map
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec

    belongs_to :user, Assistant.Schemas.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required_fields [:user_id, :token_hash, :purpose, :expires_at]
  @optional_fields [:code_verifier, :oban_job_id, :pending_intent, :used_at]

  def changeset(token, attrs) do
    token
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:purpose, @purposes)
    |> unique_constraint(:token_hash)
  end
end

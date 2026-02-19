defmodule Assistant.Schemas.AuthToken do
  @moduledoc """
  Auth token schema for magic link tokens.

  Magic links are single-use, time-limited tokens that initiate OAuth2 flows.
  The raw token (32 random bytes, base64url-encoded) is sent to the user;
  only the SHA-256 hash is stored in the database.

  The oban_job_id links to a parked PendingIntentWorker Oban job that
  replays the user's original command after OAuth completes.

  Lifecycle: generate -> user clicks link -> validate -> consume (set used_at)
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_purposes ~w(oauth_google)

  schema "auth_tokens" do
    field :token_hash, :string
    field :purpose, :string
    field :oban_job_id, :integer
    field :code_verifier, :string
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec

    belongs_to :user, Assistant.Schemas.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required_fields [:user_id, :token_hash, :purpose, :expires_at]
  @optional_fields [:oban_job_id, :code_verifier]

  def changeset(auth_token, attrs) do
    auth_token
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:purpose, @valid_purposes)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:token_hash)
  end

  @doc """
  Returns true if the token has expired.
  """
  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  @doc """
  Returns true if the token has already been consumed.
  """
  def used?(%__MODULE__{used_at: used_at}), do: not is_nil(used_at)
end

# lib/assistant/auth/token_store.ex — Encrypted CRUD for the oauth_tokens table.
#
# Provides get, upsert, delete, and validity checks for per-user OAuth tokens.
# All token fields (refresh_token, access_token) are encrypted at rest via
# Cloak.Ecto (Assistant.Encrypted.Binary). Uses Assistant.Repo directly.
#
# Related files:
#   - lib/assistant/schemas/oauth_token.ex (Ecto schema)
#   - lib/assistant/auth/oauth.ex (token exchange and refresh)
#   - lib/assistant/integrations/google/auth.ex (consumer — user_token/1)
#   - lib/assistant/encrypted/binary.ex (Cloak encryption type)

defmodule Assistant.Auth.TokenStore do
  @moduledoc """
  Encrypted CRUD operations for OAuth tokens stored in the `oauth_tokens` table.

  All token values are encrypted at rest via `Assistant.Encrypted.Binary`
  (Cloak.Ecto with AES-GCM). This module provides the data access layer;
  token refresh logic lives in `Assistant.Auth.OAuth`.
  """

  require Logger

  import Ecto.Query

  alias Assistant.Repo
  alias Assistant.Schemas.OAuthToken

  @doc """
  Fetch an OAuth token for a user and provider.

  Returns `{:ok, %OAuthToken{}}` if found, `{:error, :not_found}` otherwise.
  Token fields are decrypted transparently by Cloak.Ecto on read.
  """
  @spec get_token(binary(), String.t()) :: {:ok, OAuthToken.t()} | {:error, :not_found}
  def get_token(user_id, provider \\ "google") do
    case Repo.one(
           from(t in OAuthToken,
             where: t.user_id == ^user_id and t.provider == ^provider
           )
         ) do
      nil -> {:error, :not_found}
      token -> {:ok, token}
    end
  end

  @doc """
  Insert or update an OAuth token for a user and provider.

  Uses `Repo.insert/2` with `on_conflict` to atomically upsert. If a row
  already exists for the `(user_id, provider)` pair, it updates the token
  fields. This handles both first-time authorization and token refresh.

  ## Parameters

    * `attrs` - Map with keys:
      * `:user_id` (required) - The user's UUID
      * `:provider` (required) - Provider name (e.g., "google")
      * `:refresh_token` (required on first insert) - Plaintext refresh token (encrypted on write)
      * `:access_token` (optional) - Plaintext access token (encrypted on write)
      * `:token_expires_at` (optional) - DateTime when access token expires
      * `:provider_uid` (optional) - Google 'sub' claim
      * `:provider_email` (optional) - User's Google email
      * `:scopes` (optional) - Space-delimited granted scopes

  ## Returns

    `{:ok, %OAuthToken{}}` on success, `{:error, changeset}` on validation failure.
  """
  @spec upsert_token(map()) :: {:ok, OAuthToken.t()} | {:error, Ecto.Changeset.t()}
  def upsert_token(attrs) do
    changeset = OAuthToken.changeset(%OAuthToken{}, attrs)

    # Fields to update on conflict (everything except user_id, provider, id, inserted_at)
    update_fields = [
      :access_token,
      :token_expires_at,
      :provider_uid,
      :provider_email,
      :scopes,
      :updated_at
    ]

    # Only update refresh_token if a new one is provided (Google only sends it on first auth)
    update_fields =
      if attrs[:refresh_token] || attrs["refresh_token"] do
        [:refresh_token | update_fields]
      else
        update_fields
      end

    Repo.insert(changeset,
      on_conflict: {:replace, update_fields},
      conflict_target: [:user_id, :provider],
      returning: true
    )
  end

  @doc """
  Delete an OAuth token for a user and provider.

  Called when a refresh token is revoked (invalid_grant from Google) to force
  re-authorization via a new magic link.

  Returns `{:ok, %OAuthToken{}}` if deleted, `{:error, :not_found}` if no row existed.
  """
  @spec delete_token(binary(), String.t()) :: {:ok, OAuthToken.t()} | {:error, :not_found}
  def delete_token(user_id, provider \\ "google") do
    case Repo.one(
           from(t in OAuthToken,
             where: t.user_id == ^user_id and t.provider == ^provider
           )
         ) do
      nil ->
        {:error, :not_found}

      token ->
        Repo.delete(token)
    end
  end

  @doc """
  Check if an OAuth token's access token is still valid (not expired).

  Returns `true` if the token has an `access_token` and `token_expires_at` is
  in the future (with a 60-second buffer for clock skew).
  """
  @spec token_valid?(OAuthToken.t()) :: boolean()
  def token_valid?(%OAuthToken{access_token: nil}), do: false

  def token_valid?(%OAuthToken{token_expires_at: nil}), do: false

  def token_valid?(%OAuthToken{token_expires_at: expires_at}) do
    buffer = 60
    now = DateTime.utc_now()
    DateTime.diff(expires_at, now) > buffer
  end
end

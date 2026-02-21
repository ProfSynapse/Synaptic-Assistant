# lib/assistant/auth/token_store.ex — Encrypted CRUD for per-user OAuth tokens.
#
# Provides a context module for reading, writing, and deleting oauth_tokens
# rows. Tokens are encrypted at rest via Cloak AES-GCM (handled transparently
# by the OAuthToken schema's Encrypted.Binary fields).
#
# Related files:
#   - lib/assistant/schemas/oauth_token.ex (Ecto schema with Cloak encryption)
#   - lib/assistant/auth/oauth.ex (token exchange + refresh logic)
#   - lib/assistant/auth/magic_link.ex (magic link lifecycle)
#   - priv/repo/migrations/20260220130000_create_oauth_tokens.exs

defmodule Assistant.Auth.TokenStore do
  @moduledoc """
  Encrypted CRUD operations for per-user OAuth tokens.

  All token fields (`refresh_token`, `access_token`) are encrypted at rest
  via `Assistant.Encrypted.Binary`. This module handles storage only — token
  exchange and refresh logic lives in `Auth.OAuth`.

  ## Usage

      # Store tokens after OAuth code exchange
      {:ok, oauth_token} = TokenStore.upsert_google_token(user_id, %{
        refresh_token: "1//...",
        access_token: "ya29...",
        token_expires_at: ~U[2026-02-20 13:00:00Z],
        provider_email: "user@example.com",
        provider_uid: "12345",
        scopes: "openid email profile ..."
      })

      # Retrieve for token refresh
      {:ok, oauth_token} = TokenStore.get_google_token(user_id)

      # Delete on disconnect
      :ok = TokenStore.delete_google_token(user_id)
  """

  import Ecto.Query

  alias Assistant.Repo
  alias Assistant.Schemas.OAuthToken

  require Logger

  @google_provider "google"

  @doc """
  Get the Google OAuth token for a user.

  Returns `{:ok, %OAuthToken{}}` if found, `{:error, :not_connected}` if
  no token exists for this user.
  """
  @spec get_google_token(String.t()) :: {:ok, OAuthToken.t()} | {:error, :not_connected}
  def get_google_token(user_id) do
    case Repo.one(
           from(t in OAuthToken,
             where: t.user_id == ^user_id and t.provider == ^@google_provider
           )
         ) do
      nil -> {:error, :not_connected}
      token -> {:ok, token}
    end
  end

  @doc """
  Upsert (insert or update) Google OAuth tokens for a user.

  On conflict (same user_id + provider), updates the refresh_token,
  access_token, token_expires_at, provider_email, provider_uid, and scopes.

  ## Parameters

    - `user_id` — the user's ID
    - `attrs` — map with token fields:
      - `:refresh_token` (required) — the refresh token from Google
      - `:access_token` (optional) — the current access token
      - `:token_expires_at` (optional) — when the access token expires
      - `:provider_email` (optional) — Google account email
      - `:provider_uid` (optional) — Google 'sub' claim
      - `:scopes` (optional) — space-delimited OAuth scopes

  ## Returns

    `{:ok, %OAuthToken{}}` on success, `{:error, changeset}` on failure.
  """
  @spec upsert_google_token(String.t(), map()) ::
          {:ok, OAuthToken.t()} | {:error, Ecto.Changeset.t()}
  def upsert_google_token(user_id, attrs) do
    full_attrs =
      attrs
      |> Map.put(:user_id, user_id)
      |> Map.put(:provider, @google_provider)

    %OAuthToken{}
    |> OAuthToken.changeset(full_attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :refresh_token,
           :access_token,
           :token_expires_at,
           :provider_email,
           :provider_uid,
           :scopes,
           :updated_at
         ]},
      conflict_target: [:user_id, :provider],
      returning: true
    )
  end

  @doc """
  Update the cached access_token and its expiry for a user's Google token.

  Called after a successful token refresh to cache the new access token,
  avoiding unnecessary refreshes on subsequent requests within the token's
  lifetime.

  Returns `{:ok, %OAuthToken{}}` or `{:error, :not_connected}`.
  """
  @spec update_access_token(String.t(), String.t(), DateTime.t()) ::
          {:ok, OAuthToken.t()} | {:error, :not_connected | Ecto.Changeset.t()}
  def update_access_token(user_id, access_token, expires_at) do
    case get_google_token(user_id) do
      {:ok, token} ->
        token
        |> Ecto.Changeset.change(access_token: access_token, token_expires_at: expires_at)
        |> Repo.update()

      {:error, :not_connected} = error ->
        error
    end
  end

  @doc """
  Delete the Google OAuth token for a user (disconnect).

  Returns `:ok` if deleted or if no token existed (idempotent).
  """
  @spec delete_google_token(String.t()) :: :ok
  def delete_google_token(user_id) do
    {_count, _} =
      from(t in OAuthToken,
        where: t.user_id == ^user_id and t.provider == ^@google_provider
      )
      |> Repo.delete_all()

    :ok
  end

  @doc """
  Check if a user has a connected Google account.

  Returns `true` if an oauth_tokens row exists for this user+provider.
  """
  @spec google_connected?(String.t()) :: boolean()
  def google_connected?(user_id) do
    Repo.exists?(
      from(t in OAuthToken,
        where: t.user_id == ^user_id and t.provider == ^@google_provider
      )
    )
  end

  @doc """
  Check if the cached access_token is still valid (not expired).

  Returns `true` if the token exists and `token_expires_at` is in the future
  (with a 60-second buffer for clock skew).
  """
  @spec access_token_valid?(OAuthToken.t()) :: boolean()
  def access_token_valid?(%OAuthToken{access_token: nil}), do: false

  def access_token_valid?(%OAuthToken{token_expires_at: nil}), do: false

  def access_token_valid?(%OAuthToken{token_expires_at: expires_at}) do
    buffer = 60
    DateTime.compare(expires_at, DateTime.add(DateTime.utc_now(), buffer, :second)) == :gt
  end
end

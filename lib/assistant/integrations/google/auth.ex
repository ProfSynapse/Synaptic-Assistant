# lib/assistant/integrations/google/auth.ex — Dual-mode Google authentication.
#
# Provides two authentication paths:
#   1. service_token/0 — Service account token via Goth (for Chat bot operations)
#   2. user_token/1    — Per-user OAuth2 token (for Gmail, Drive, Calendar)
#
# The service account (via Goth) handles only the chat.bot scope. All user-facing
# Google API calls (Gmail, Drive, Calendar) use per-user OAuth2 tokens stored in
# the oauth_tokens table and refreshed statelessly via Goth.Token.fetch/1.
#
# Related files:
#   - lib/assistant/auth/oauth.ex (token exchange and refresh logic)
#   - lib/assistant/auth/token_store.ex (encrypted CRUD for oauth_tokens)
#   - lib/assistant/auth/magic_link.ex (magic link generation for auth flow)
#   - lib/assistant/application.ex (starts Goth for service account)
#   - config/runtime.exs (Google credentials configuration)

defmodule Assistant.Integrations.Google.Auth do
  @moduledoc """
  Dual-mode Google authentication: service account for Chat bot, per-user OAuth2
  for Gmail/Drive/Calendar.

  ## Service Account (Chat Bot)

      case Auth.service_token() do
        {:ok, access_token} -> # use for Chat API calls
        {:error, reason} -> # Goth not configured or refresh failed
      end

  ## Per-User OAuth2

      case Auth.user_token(user_id) do
        {:ok, access_token} -> # use for Gmail/Drive/Calendar API calls
        {:error, :not_connected} -> # user needs to authorize via magic link
        {:error, :refresh_failed} -> # refresh token revoked; token deleted, re-auth needed
      end
  """

  require Logger

  alias Assistant.Auth.OAuth
  alias Assistant.Auth.TokenStore
  alias Assistant.Repo

  @goth_name Assistant.Goth

  # --- Service Account (Chat Bot) ---

  @doc """
  Fetch a service account access token from the Goth instance.

  Used exclusively for Google Chat bot operations (chat.bot scope).
  Returns `{:ok, token_string}` on success or `{:error, reason}` on failure.
  """
  @spec service_token() :: {:ok, String.t()} | {:error, term()}
  def service_token do
    case Goth.fetch(@goth_name) do
      {:ok, %{token: access_token}} ->
        {:ok, access_token}

      {:error, reason} = error ->
        Logger.warning("Failed to fetch Google service account token: #{inspect(reason)}")
        error
    end
  end

  # --- Per-User OAuth2 ---

  @doc """
  Fetch a per-user OAuth2 access token.

  Checks the token store for the user's Google OAuth token:
  1. If found and valid (not expired) — returns the access token
  2. If found but expired — attempts stateless refresh via Goth.Token.fetch/1
  3. If not found — returns `{:error, :not_connected}`
  4. If refresh fails with `invalid_grant` — deletes the token and returns
     `{:error, :not_connected}` (forces re-authorization via magic link)

  ## Parameters

    * `user_id` - The user's UUID

  ## Returns

    * `{:ok, access_token}` — valid token ready for API calls
    * `{:error, :not_connected}` — user has no token; trigger magic link flow
    * `{:error, :refresh_failed}` — refresh attempt failed for non-revocation reason
  """
  @spec user_token(binary()) ::
          {:ok, String.t()} | {:error, :not_connected | :refresh_failed}
  def user_token(user_id) do
    case TokenStore.get_token(user_id) do
      {:error, :not_found} ->
        {:error, :not_connected}

      {:ok, oauth_token} ->
        if TokenStore.token_valid?(oauth_token) do
          {:ok, oauth_token.access_token}
        else
          # Serialize refresh attempts per-user via PostgreSQL advisory lock.
          # This prevents a TOCTOU race where two concurrent requests both see
          # an expired token, both refresh, and the second refresh causes
          # Google to revoke the first — deleting the just-saved token.
          with_user_advisory_lock(user_id, fn ->
            # Re-check inside the lock — another request may have refreshed already
            case TokenStore.get_token(user_id) do
              {:error, :not_found} ->
                {:error, :not_connected}

              {:ok, fresh_token} ->
                if TokenStore.token_valid?(fresh_token) do
                  {:ok, fresh_token.access_token}
                else
                  refresh_user_token(user_id, fresh_token)
                end
            end
          end)
        end
    end
  end

  # --- Configuration ---

  @doc """
  Check whether Google service account credentials are configured.

  Returns `true` if the `:google_credentials` application env is set.
  Useful for feature-gating Chat bot functionality.
  """
  @spec configured?() :: boolean()
  def configured? do
    Application.get_env(:assistant, :google_credentials) != nil
  end

  @doc """
  Check whether Google OAuth2 client credentials are configured.

  Returns `true` if both `GOOGLE_OAUTH_CLIENT_ID` and `GOOGLE_OAUTH_CLIENT_SECRET`
  are set. Required for per-user OAuth2 flow.
  """
  @spec oauth_configured?() :: boolean()
  def oauth_configured? do
    Application.get_env(:assistant, :google_oauth_client_id) != nil and
      Application.get_env(:assistant, :google_oauth_client_secret) != nil
  end

  @doc """
  The required Google API scopes for the service account (Chat bot only).

  Per-user scopes are defined in `Assistant.Auth.OAuth.user_scopes/0`.
  """
  @spec scopes() :: [String.t()]
  def scopes do
    ["https://www.googleapis.com/auth/chat.bot"]
  end

  # --- Private ---

  # Serialize an operation per user via a PostgreSQL advisory transaction lock.
  # Uses a deterministic lock key derived from the user_id. The lock is released
  # automatically when the transaction commits/rolls back.
  defp with_user_advisory_lock(user_id, fun) do
    lock_key = user_id_to_lock_key(user_id)

    Repo.transaction(fn ->
      case Ecto.Adapters.SQL.query(Repo, "SELECT pg_advisory_xact_lock($1)", [lock_key]) do
        {:ok, _} ->
          fun.()

        {:error, reason} ->
          Logger.error("Failed to acquire advisory lock for token refresh",
            user_id: user_id,
            reason: inspect(reason)
          )

          {:error, :refresh_failed}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  # Convert a UUID string to a deterministic 64-bit integer for pg_advisory_xact_lock.
  # Uses the first 8 bytes of the binary UUID as a signed 64-bit integer.
  defp user_id_to_lock_key(user_id) do
    <<key::signed-integer-64, _rest::binary>> = :crypto.hash(:sha256, user_id)
    key
  end

  defp refresh_user_token(user_id, oauth_token) do
    case OAuth.refresh_token(oauth_token.refresh_token) do
      {:ok, %{access_token: new_access_token, expires_at: expires_at}} ->
        # Update stored token with new access token and expiry
        TokenStore.upsert_token(%{
          user_id: user_id,
          provider: "google",
          access_token: new_access_token,
          token_expires_at: expires_at
        })

        {:ok, new_access_token}

      {:error, :invalid_grant} ->
        # Refresh token revoked — delete the stored token so next call
        # returns :not_connected, triggering a new magic link flow
        Logger.warning("OAuth refresh token revoked, deleting stored token",
          user_id: user_id
        )

        TokenStore.delete_token(user_id)
        {:error, :not_connected}

      {:error, reason} ->
        Logger.error("OAuth token refresh failed",
          user_id: user_id,
          reason: inspect(reason)
        )

        {:error, :refresh_failed}
    end
  end
end

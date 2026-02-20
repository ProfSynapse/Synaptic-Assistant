# lib/assistant/integrations/google/auth.ex — Dual-mode Google auth wrapper.
#
# Provides two token paths:
#   1. service_token/0 — Goth service account for Google Chat bot operations
#   2. user_token/1 — Per-user OAuth2 token from oauth_tokens table, with
#      automatic refresh when expired via Auth.OAuth.refresh_access_token/1
#
# Related files:
#   - lib/assistant/application.ex (starts Goth in the supervision tree)
#   - lib/assistant/auth/oauth.ex (stateless token exchange + refresh)
#   - lib/assistant/auth/token_store.ex (encrypted CRUD for oauth_tokens)
#   - config/runtime.exs (Google credentials configuration)
#   - lib/assistant/integrations/google/drive.ex (consumer — Drive API)
#   - lib/assistant/integrations/google/chat.ex (consumer — Chat API)
#   - lib/assistant/integrations/google/gmail.ex (consumer — Gmail API)
#   - lib/assistant/integrations/google/calendar.ex (consumer — Calendar API)

defmodule Assistant.Integrations.Google.Auth do
  @moduledoc """
  Dual-mode Google OAuth2 token management.

  Two authentication paths:

  - `service_token/0` — Goth service account token for Google Chat bot
    operations. Tokens are auto-refreshed by the supervised Goth process.

  - `user_token/1` — Per-user OAuth2 token from the `oauth_tokens` table.
    Checks whether the cached access token is still valid; if expired,
    transparently refreshes via `Auth.OAuth.refresh_access_token/1` and
    caches the new token in the database.

  ## Usage

      # Service account (Chat bot)
      case Auth.service_token() do
        {:ok, access_token} -> # use for Chat API calls
        {:error, reason} -> # handle missing credentials
      end

      # Per-user token (Drive, Gmail, Calendar)
      case Auth.user_token(user_id) do
        {:ok, access_token} -> # use for user-scoped API calls
        {:error, :not_connected} -> # user needs to connect Google account
        {:error, :refresh_failed} -> # refresh token revoked or invalid
      end
  """

  require Logger

  alias Assistant.Auth.{OAuth, TokenStore}

  @goth_name Assistant.Goth

  # --- Service Account (Chat bot) ---

  @doc """
  Fetch a service account access token from the supervised Goth instance.

  Used exclusively for Google Chat bot operations. All other Google API
  calls (Drive, Gmail, Calendar) use `user_token/1` with per-user OAuth.

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

  # --- Per-User Token ---

  @doc """
  Fetch a per-user access token for Google API calls.

  Looks up the user's stored OAuth token, checks validity, and refreshes
  if expired. The refreshed token is cached in the database to avoid
  redundant refresh calls within the token's lifetime (~1 hour).

  ## Returns

    - `{:ok, access_token}` — valid access token ready for API calls
    - `{:error, :not_connected}` — no OAuth token stored for this user
    - `{:error, :refresh_failed}` — refresh token is invalid or revoked;
      user needs to re-authorize via magic link
  """
  @spec user_token(String.t()) :: {:ok, String.t()} | {:error, :not_connected | :refresh_failed}
  def user_token(user_id) do
    case TokenStore.get_google_token(user_id) do
      {:error, :not_connected} = error ->
        error

      {:ok, oauth_token} ->
        if TokenStore.access_token_valid?(oauth_token) do
          {:ok, oauth_token.access_token}
        else
          refresh_and_cache(user_id, oauth_token.refresh_token)
        end
    end
  end

  # --- Legacy Compatibility ---

  @doc """
  Check whether Google service account credentials are configured.

  Returns `true` if the `:google_credentials` application env is set.
  """
  @spec configured?() :: boolean()
  def configured? do
    Application.get_env(:assistant, :google_credentials) != nil
  end

  @doc """
  The Google Chat bot scope (service account only).

  Per-user scopes are defined in `Auth.OAuth.user_scopes/0`.
  """
  @spec scopes() :: [String.t()]
  def scopes do
    ["https://www.googleapis.com/auth/chat.bot"]
  end

  # --- Private ---

  defp refresh_and_cache(user_id, refresh_token) do
    case OAuth.refresh_access_token(refresh_token) do
      {:ok, access_token} ->
        # Cache the refreshed token with a ~1 hour expiry
        expires_at = DateTime.add(DateTime.utc_now(), 3500, :second)

        case TokenStore.update_access_token(user_id, access_token, expires_at) do
          {:ok, _} -> :ok
          {:error, reason} ->
            Logger.warning("Failed to cache refreshed token",
              user_id: user_id,
              reason: inspect(reason)
            )
        end

        {:ok, access_token}

      {:error, :refresh_failed} ->
        Logger.warning("Token refresh failed for user — may need re-authorization",
          user_id: user_id
        )

        {:error, :refresh_failed}

      {:error, reason} ->
        Logger.warning("Token refresh error",
          user_id: user_id,
          reason: inspect(reason)
        )

        {:error, :refresh_failed}
    end
  end
end

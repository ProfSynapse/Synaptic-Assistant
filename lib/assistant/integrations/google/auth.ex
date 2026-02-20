# lib/assistant/integrations/google/auth.ex — Dual-mode Google auth wrapper.
#
# Provides two token paths:
#   1. service_token/0 — Goth service account for Google Chat bot operations
#   2. user_token/1 — Per-user OAuth2 token from oauth_tokens table, with
#      automatic refresh when expired via Auth.OAuth.refresh_access_token/1
#
# Concurrent refresh safety:
#   When multiple requests hit an expired token simultaneously, :global.trans/3
#   serializes refresh calls per-user. The first process acquires the lock and
#   performs the Google refresh; subsequent processes wait, then re-check the
#   DB for the freshly cached token (double-checked locking pattern).
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

  ## Concurrent Refresh Safety

  When multiple requests for the same user arrive simultaneously with an
  expired token, `:global.trans/3` serializes refresh calls per-user:

  1. The first process acquires a per-user lock and performs the refresh.
  2. Concurrent processes block on the lock, then re-check the DB for
     the freshly cached token (double-checked locking).
  3. No additional supervision tree entries or GenServers required.

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
          serialized_refresh(user_id, oauth_token.refresh_token)
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

  # Serialize concurrent refreshes for the same user via :global.trans/3.
  # Uses double-checked locking: after acquiring the lock, re-reads the DB
  # to see if another process already refreshed the token while we waited.
  defp serialized_refresh(user_id, refresh_token) do
    lock_id = {:token_refresh, user_id}

    # :global.trans/3 acquires a cluster-wide lock on {lock_id, self()}.
    # All processes for the same user_id serialize here. The lock is
    # released when the function returns.
    result =
      :global.trans({lock_id, self()}, fn ->
        # Double-check: re-read from DB — another process may have refreshed
        # while we were waiting for the lock.
        case TokenStore.get_google_token(user_id) do
          {:ok, fresh_token} ->
            if TokenStore.access_token_valid?(fresh_token) do
              {:ok, fresh_token.access_token}
            else
              refresh_and_cache(user_id, refresh_token)
            end

          {:error, :not_connected} ->
            {:error, :not_connected}
        end
      end)

    # :global.trans returns :aborted if it cannot acquire the lock
    # (e.g., nodes disagree). Fall back to a direct refresh attempt.
    case result do
      :aborted ->
        Logger.warning("Global lock acquisition failed, falling back to direct refresh",
          user_id: user_id
        )

        refresh_and_cache(user_id, refresh_token)

      other ->
        other
    end
  end

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

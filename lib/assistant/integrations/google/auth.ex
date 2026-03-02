# lib/assistant/integrations/google/auth.ex — Dual-mode Google auth wrapper.
#
# Provides two token paths:
#   1. service_token/0 — Service account token for Google Chat bot operations,
#      obtained via direct JWT assertion (no Goth dependency).
#   2. user_token/1 — Per-user OAuth2 token from oauth_tokens table, with
#      automatic refresh when expired via Auth.OAuth.refresh_access_token/1
#
# Service account token flow (service_token/0):
#   Reads the service account JSON from IntegrationSettings
#   (:google_service_account_json key, env var GOOGLE_APPLICATION_CREDENTIALS).
#   The value can be raw JSON or a file path. Creates a signed JWT assertion
#   using JOSE, exchanges it at Google's token endpoint, and caches the result
#   in ETS with TTL tracking. Concurrent callers are serialized via
#   :global.trans/3 to prevent thundering herd on expiry.
#
# Per-user token concurrent refresh safety:
#   When multiple requests hit an expired token simultaneously, :global.trans/3
#   serializes refresh calls per-user. The first process acquires the lock and
#   performs the Google refresh; subsequent processes wait, then re-check the
#   DB for the freshly cached token (double-checked locking pattern).
#
# Related files:
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

  - `service_token/0` — Service account token for Google Chat bot operations.
    Creates a JWT assertion signed with the service account's private key,
    exchanges it at Google's OAuth2 token endpoint, and caches the result
    in ETS (~1 hour TTL). No external dependencies (replaces Goth).

  - `user_token/1` — Per-user OAuth2 token from the `oauth_tokens` table.
    Checks whether the cached access token is still valid; if expired,
    transparently refreshes via `Auth.OAuth.refresh_access_token/1` and
    caches the new token in the database.

  ## Concurrent Refresh Safety

  Both token paths use `:global.trans/3` to serialize concurrent refreshes:

  1. The first process acquires a lock and performs the refresh/exchange.
  2. Concurrent processes block on the lock, then re-check the cache/DB for
     the freshly obtained token (double-checked locking).
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
  alias Assistant.IntegrationSettings

  @google_token_url "https://oauth2.googleapis.com/token"
  @chat_bot_scope "https://www.googleapis.com/auth/chat.bot"
  @jwt_lifetime_seconds 3600
  @token_cache_table :google_service_token_cache
  # Refresh 5 minutes before expiry to avoid edge-case failures
  @token_refresh_margin_seconds 300

  # --- Service Account (Chat bot) ---

  @doc """
  Fetch a service account access token for Google Chat bot operations.

  Creates a JWT assertion signed with the service account's RSA private key,
  exchanges it at Google's token endpoint for an access token, and caches the
  result in ETS. Subsequent calls return the cached token until it nears expiry.

  Requires service account credentials configured via
  `IntegrationSettings.get(:google_service_account_json)` — either raw JSON
  content or a file path to the service account JSON file.

  Returns `{:ok, token_string}` on success or `{:error, reason}` on failure.
  """
  @spec service_token() :: {:ok, String.t()} | {:error, term()}
  def service_token do
    case get_cached_service_token() do
      {:ok, _token} = hit ->
        hit

      :miss ->
        fetch_service_token_serialized()
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

  # --- Configuration Checks ---

  @doc """
  Check whether Google service account credentials are configured.

  Returns `true` if `:google_service_account_json` is set via
  IntegrationSettings (DB value or GOOGLE_APPLICATION_CREDENTIALS env var)
  and contains valid `client_email` and `private_key` fields.
  """
  @spec configured?() :: boolean()
  def configured? do
    case load_service_account_credentials() do
      {:ok, _client_email, _private_key} -> true
      :error -> false
    end
  end

  @doc """
  Check whether Google OAuth2 client credentials are configured.

  Returns `true` if both `GOOGLE_OAUTH_CLIENT_ID` and `GOOGLE_OAUTH_CLIENT_SECRET`
  are set. Required for per-user OAuth2 flow.
  """
  @spec oauth_configured?() :: boolean()
  def oauth_configured? do
    IntegrationSettings.get(:google_oauth_client_id) != nil and
      IntegrationSettings.get(:google_oauth_client_secret) != nil
  end

  # --- Private: Service Account Token ---

  # Check ETS cache for a valid (non-expired) service account token.
  defp get_cached_service_token do
    ensure_token_cache()

    case :ets.lookup(@token_cache_table, :service_token) do
      [{:service_token, token, expires_at}] ->
        if System.system_time(:second) < expires_at - @token_refresh_margin_seconds do
          {:ok, token}
        else
          :miss
        end

      [] ->
        :miss
    end
  end

  # Serialize concurrent service token fetches via :global.trans/3.
  # Double-checked locking: after acquiring the lock, re-check cache
  # in case another process already fetched while we waited.
  defp fetch_service_token_serialized do
    result =
      :global.trans({:service_token_refresh, self()}, fn ->
        case get_cached_service_token() do
          {:ok, _token} = hit ->
            hit

          :miss ->
            do_fetch_service_token()
        end
      end)

    case result do
      :aborted ->
        Logger.warning("Service token lock acquisition failed, falling back to direct fetch")
        do_fetch_service_token()

      other ->
        other
    end
  end

  # Load service account credentials, build JWT assertion, sign, and exchange.
  defp do_fetch_service_token do
    case load_service_account_credentials() do
      {:ok, client_email, private_key_pem} ->
        fetch_token_via_jwt(client_email, private_key_pem)

      :error ->
        Logger.warning("Google service account credentials not configured")
        {:error, :not_configured}
    end
  end

  # Load and parse service account credentials from IntegrationSettings.
  # The value can be either raw JSON content or a file path to the JSON file.
  defp load_service_account_credentials do
    case IntegrationSettings.get(:google_service_account_json) do
      nil ->
        :error

      value when is_binary(value) ->
        parse_service_account_value(value)

      _ ->
        :error
    end
  end

  defp parse_service_account_value(value) do
    # Try parsing as JSON first; if that fails, treat as file path
    case Jason.decode(value) do
      {:ok, %{"client_email" => email, "private_key" => key}}
      when is_binary(email) and is_binary(key) ->
        {:ok, email, key}

      {:ok, _} ->
        Logger.warning("Service account JSON missing client_email or private_key fields")
        :error

      {:error, _} ->
        # Not valid JSON — try reading as file path
        read_service_account_file(value)
    end
  end

  defp read_service_account_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"client_email" => email, "private_key" => key}}
          when is_binary(email) and is_binary(key) ->
            {:ok, email, key}

          _ ->
            Logger.warning("Service account file missing client_email or private_key",
              path: path
            )

            :error
        end

      {:error, reason} ->
        Logger.warning("Failed to read service account file",
          path: path,
          reason: inspect(reason)
        )

        :error
    end
  end

  defp fetch_token_via_jwt(client_email, private_key_pem) do
    now = System.system_time(:second)

    claims = %{
      "iss" => client_email,
      "scope" => @chat_bot_scope,
      "aud" => @google_token_url,
      "iat" => now,
      "exp" => now + @jwt_lifetime_seconds
    }

    with {:ok, jwk} <- parse_private_key(private_key_pem),
         {:ok, signed_jwt} <- sign_jwt(jwk, claims),
         {:ok, token, expires_in} <- exchange_jwt(signed_jwt) do
      expires_at = now + expires_in
      cache_service_token(token, expires_at)
      {:ok, token}
    end
  end

  defp parse_private_key(pem) do
    try do
      jwk = JOSE.JWK.from_pem(pem)
      {:ok, jwk}
    rescue
      error ->
        Logger.error("Failed to parse service account private key: #{inspect(error)}")
        {:error, :invalid_private_key}
    end
  end

  defp sign_jwt(jwk, claims) do
    try do
      jws = %{"alg" => "RS256", "typ" => "JWT"}
      {_, compact} = JOSE.JWT.sign(jwk, jws, claims) |> JOSE.JWS.compact()
      {:ok, compact}
    rescue
      error ->
        Logger.error("Failed to sign service account JWT: #{inspect(error)}")
        {:error, :jwt_signing_failed}
    end
  end

  defp exchange_jwt(signed_jwt) do
    body = %{
      "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
      "assertion" => signed_jwt
    }

    case Req.post(@google_token_url, form: body) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => token} = resp_body}} ->
        expires_in = Map.get(resp_body, "expires_in", @jwt_lifetime_seconds)
        {:ok, token, expires_in}

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        Logger.error("Google token exchange failed",
          status: status,
          body: inspect(resp_body)
        )

        {:error, {:token_exchange_failed, status}}

      {:error, reason} ->
        Logger.error("Google token exchange request failed: #{inspect(reason)}")
        {:error, {:token_exchange_failed, reason}}
    end
  end

  defp cache_service_token(token, expires_at) do
    ensure_token_cache()
    :ets.insert(@token_cache_table, {:service_token, token, expires_at})
  end

  defp ensure_token_cache do
    case :ets.whereis(@token_cache_table) do
      :undefined ->
        :ets.new(@token_cache_table, [:set, :public, :named_table])

      _ref ->
        :ok
    end
  rescue
    ArgumentError ->
      # Table may have been created by another process between check and create
      :ok
  end

  # --- Private: Per-User Token ---

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
          {:ok, _} ->
            :ok

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

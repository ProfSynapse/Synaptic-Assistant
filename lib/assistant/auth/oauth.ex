# lib/assistant/auth/oauth.ex — Stateless Google OAuth2 helpers.
#
# Provides three capabilities:
#   1. Authorization URL builder (with PKCE S256 + HMAC-signed state)
#   2. Authorization code exchange via Req HTTP POST
#   3. Stateless per-user token refresh via Goth.Token.fetch/1
#
# This module is pure-functional — no processes, no state. Token storage
# is handled by Auth.TokenStore (separate module). The existing Goth
# supervised process (Assistant.Goth) is used only for the service account;
# per-user refresh uses Goth.Token.fetch/1 in stateless mode.
#
# Related files:
#   - lib/assistant/integrations/google/auth.ex (service account token — unchanged)
#   - lib/assistant/auth/token_store.ex (encrypted CRUD for oauth_tokens table)
#   - lib/assistant/auth/magic_link.ex (magic link lifecycle)
#   - lib/assistant_web/controllers/oauth_controller.ex (callback handler)
#   - config/runtime.exs (GOOGLE_OAUTH_CLIENT_ID, GOOGLE_OAUTH_CLIENT_SECRET)

defmodule Assistant.Auth.OAuth do
  @moduledoc """
  Stateless Google OAuth2 operations: URL building, code exchange, and
  per-user token refresh.

  ## Authorization URL

      {:ok, url, pkce} = OAuth.authorize_url(user_id, channel, token_hash)
      # pkce.code_verifier must be stored for the callback

  ## Code Exchange

      {:ok, token_data} = OAuth.exchange_code(code, redirect_uri, code_verifier)
      # token_data contains access_token, refresh_token, id_token, etc.

  ## Token Refresh

      {:ok, access_token} = OAuth.refresh_access_token(refresh_token)
      # Uses Goth.Token.fetch/1 stateless mode — no running process needed
  """

  require Logger

  @google_authorize_url "https://accounts.google.com/o/oauth2/v2/auth"
  @google_token_url "https://oauth2.googleapis.com/token"

  # Scopes for per-user OAuth (excludes chat.bot — that stays on service account)
  @user_scopes [
    "openid",
    "email",
    "profile",
    "https://www.googleapis.com/auth/drive.readonly",
    "https://www.googleapis.com/auth/drive.file",
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/calendar"
  ]

  @state_hmac_ttl_seconds 600
  @code_verifier_length 64

  # --- Types ---

  @type pkce :: %{code_verifier: String.t(), code_challenge: String.t()}

  @type token_data :: %{
          optional(:access_token) => String.t(),
          optional(:refresh_token) => String.t(),
          optional(:id_token) => String.t(),
          optional(:expires_in) => integer(),
          optional(:token_type) => String.t(),
          optional(:scope) => String.t()
        }

  # --- Public API ---

  @doc """
  Build a Google OAuth2 authorization URL with PKCE (S256) and HMAC-signed state.

  ## Parameters

    - `user_id` — the user initiating the flow (bound into the state parameter)
    - `channel` — the channel through which the user is interacting (e.g., "google_chat")
    - `token_hash` — SHA-256 hash of the magic link token (bound into state for verification)

  ## Returns

    `{:ok, url, pkce}` where:
    - `url` is the full Google authorization URL to redirect the user to
    - `pkce` is `%{code_verifier: ..., code_challenge: ...}` — the verifier must be
      persisted (in the auth_tokens row) for use in the callback's code exchange

    `{:error, reason}` if client credentials are not configured.
  """
  @spec authorize_url(String.t(), String.t(), String.t()) ::
          {:ok, String.t(), pkce()} | {:error, term()}
  def authorize_url(user_id, channel, token_hash) do
    with {:ok, client_id} <- fetch_client_id() do
      pkce = generate_pkce()
      state = sign_state(user_id, channel, token_hash)

      params =
        URI.encode_query(%{
          "client_id" => client_id,
          "redirect_uri" => callback_url(),
          "response_type" => "code",
          "scope" => Enum.join(@user_scopes, " "),
          "state" => state,
          "access_type" => "offline",
          "prompt" => "consent",
          "code_challenge" => pkce.code_challenge,
          "code_challenge_method" => "S256"
        })

      url = "#{@google_authorize_url}?#{params}"
      {:ok, url, pkce}
    end
  end

  @doc """
  Exchange an authorization code for tokens.

  ## Parameters

    - `code` — the authorization code from the Google callback
    - `code_verifier` — the PKCE code_verifier generated during `authorize_url/3`

  ## Returns

    `{:ok, token_data}` where token_data is a map with string keys containing
    at minimum `"access_token"` and `"refresh_token"`.

    `{:error, reason}` on failure.
  """
  @spec exchange_code(String.t(), String.t()) :: {:ok, token_data()} | {:error, term()}
  def exchange_code(code, code_verifier) do
    with {:ok, client_id} <- fetch_client_id(),
         {:ok, client_secret} <- fetch_client_secret() do
      form = %{
        "code" => code,
        "client_id" => client_id,
        "client_secret" => client_secret,
        "redirect_uri" => callback_url(),
        "grant_type" => "authorization_code",
        "code_verifier" => code_verifier
      }

      case Req.post(@google_token_url, form: form) do
        {:ok, %Req.Response{status: 200, body: %{} = body}} ->
          Logger.info("OAuth code exchange succeeded",
            has_refresh_token: is_binary(body["refresh_token"])
          )

          {:ok, body}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.warning("OAuth code exchange failed",
            status: status,
            error: inspect(body["error"]),
            description: inspect(body["error_description"])
          )

          {:error, {:token_exchange_failed, status, body}}

        {:error, reason} ->
          Logger.error("OAuth code exchange HTTP error", reason: inspect(reason))
          {:error, {:token_exchange_http_error, reason}}
      end
    end
  end

  @doc """
  Refresh an access token using a stored refresh_token via Goth stateless mode.

  Uses `Goth.Token.fetch/1` with a `{:refresh_token, ...}` source, which
  performs a single HTTP call to Google's token endpoint and returns a fresh
  access token. No running Goth process is needed.

  ## Parameters

    - `refresh_token` — the user's stored refresh token (decrypted)

  ## Returns

    `{:ok, access_token}` with a fresh access token string.
    `{:error, :refresh_failed}` if the refresh token is invalid or revoked.
    `{:error, term()}` for other failures.
  """
  @spec refresh_access_token(String.t()) :: {:ok, String.t()} | {:error, term()}
  def refresh_access_token(refresh_token) do
    with {:ok, client_id} <- fetch_client_id(),
         {:ok, client_secret} <- fetch_client_secret() do
      credentials = %{
        "client_id" => client_id,
        "client_secret" => client_secret,
        "refresh_token" => refresh_token
      }

      case Goth.Token.fetch(source: {:refresh_token, credentials}) do
        {:ok, %{token: access_token}} ->
          {:ok, access_token}

        {:error, reason} ->
          Logger.warning("OAuth token refresh failed",
            reason: inspect(reason)
          )

          {:error, :refresh_failed}
      end
    end
  end

  @doc """
  Revoke an OAuth token at Google's revocation endpoint.

  Should be called before deleting the token from the database so that the
  grant is invalidated server-side and cannot be reused. Revocation failure
  is non-fatal — the caller should log a warning and continue with local
  deletion.

  ## Parameters

    - `access_token` — the access token (or refresh token) to revoke

  ## Returns

    `:ok` on successful revocation.
    `{:error, reason}` if the HTTP call fails or Google returns an error.
  """
  @spec revoke_token(String.t()) :: :ok | {:error, term()}
  def revoke_token(access_token) when is_binary(access_token) and access_token != "" do
    url = "https://oauth2.googleapis.com/revoke"

    case Req.post(url, form: %{"token" => access_token}) do
      {:ok, %Req.Response{status: 200}} ->
        Logger.info("Google OAuth token revoked successfully")
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Google OAuth token revocation returned non-200",
          status: status,
          body: inspect(body)
        )

        {:error, {:revocation_failed, status}}

      {:error, reason} ->
        Logger.warning("Google OAuth token revocation HTTP error",
          reason: inspect(reason)
        )

        {:error, {:revocation_http_error, reason}}
    end
  end

  def revoke_token(_), do: {:error, :no_token}

  @doc """
  Verify and decode an HMAC-signed state parameter from the OAuth callback.

  ## Parameters

    - `state` — the state parameter received in the callback

  ## Returns

    `{:ok, %{user_id: ..., channel: ..., token_hash: ...}}` if valid and not expired.
    `{:error, :invalid_state}` if the HMAC doesn't match or the state is expired.
  """
  @spec verify_state(String.t()) :: {:ok, map()} | {:error, :invalid_state}
  def verify_state(state) do
    case Base.url_decode64(state, padding: false) do
      {:ok, decoded} ->
        case String.split(decoded, "|") do
          [user_id, channel, token_hash, timestamp_str, signature] ->
            payload = "#{user_id}|#{channel}|#{token_hash}|#{timestamp_str}"
            expected_sig = compute_hmac(payload)

            with true <- Plug.Crypto.secure_compare(signature, expected_sig),
                 {timestamp, ""} <- Integer.parse(timestamp_str),
                 true <- System.system_time(:second) - timestamp <= @state_hmac_ttl_seconds do
              {:ok, %{user_id: user_id, channel: channel, token_hash: token_hash}}
            else
              _ -> {:error, :invalid_state}
            end

          _ ->
            {:error, :invalid_state}
        end

      :error ->
        {:error, :invalid_state}
    end
  end

  @doc """
  Decode the ID token from a Google OAuth response to extract user claims.

  Performs base64 decoding of the JWT payload only (no signature verification,
  as we trust the token since it came directly from Google's token endpoint
  over HTTPS in the same request).

  ## Returns

    `{:ok, claims_map}` with at minimum `"email"` and `"sub"` keys.
    `{:error, :invalid_id_token}` if the token cannot be decoded.
  """
  @spec decode_id_token(String.t()) :: {:ok, map()} | {:error, :invalid_id_token}
  def decode_id_token(id_token) do
    case String.split(id_token, ".") do
      [_header, payload, _signature] ->
        with {:ok, json} <- Base.url_decode64(payload, padding: false),
             {:ok, claims} <- Jason.decode(json) do
          {:ok, claims}
        else
          _ -> {:error, :invalid_id_token}
        end

      _ ->
        {:error, :invalid_id_token}
    end
  end

  @doc """
  Returns the per-user OAuth scopes requested during authorization.
  """
  @spec user_scopes() :: [String.t()]
  def user_scopes, do: @user_scopes

  @doc """
  Returns the OAuth callback URL for this application.
  """
  @spec callback_url() :: String.t()
  def callback_url do
    AssistantWeb.Endpoint.url() <> "/auth/google/callback"
  end

  # --- PKCE ---

  @doc false
  @spec generate_pkce() :: pkce()
  def generate_pkce do
    verifier =
      :crypto.strong_rand_bytes(@code_verifier_length)
      |> Base.url_encode64(padding: false)

    challenge =
      :crypto.hash(:sha256, verifier)
      |> Base.url_encode64(padding: false)

    %{code_verifier: verifier, code_challenge: challenge}
  end

  # --- State HMAC ---

  defp sign_state(user_id, channel, token_hash) do
    timestamp = System.system_time(:second) |> Integer.to_string()
    payload = "#{user_id}|#{channel}|#{token_hash}|#{timestamp}"
    signature = compute_hmac(payload)
    raw = "#{payload}|#{signature}"
    Base.url_encode64(raw, padding: false)
  end

  defp compute_hmac(payload) do
    key = state_signing_key()

    :crypto.mac(:hmac, :sha256, key, payload)
    |> Base.url_encode64(padding: false)
  end

  defp state_signing_key do
    # Use the Phoenix secret_key_base as the HMAC key.
    # This is always available and is already a strong secret.
    AssistantWeb.Endpoint.config(:secret_key_base)
  end

  # --- Client Credentials ---

  defp fetch_client_id do
    case Application.get_env(:assistant, :google_oauth_client_id) do
      client_id when is_binary(client_id) and client_id != "" ->
        {:ok, client_id}

      _ ->
        {:error, :missing_google_oauth_client_id}
    end
  end

  defp fetch_client_secret do
    case Application.get_env(:assistant, :google_oauth_client_secret) do
      client_secret when is_binary(client_secret) and client_secret != "" ->
        {:ok, client_secret}

      _ ->
        {:error, :missing_google_oauth_client_secret}
    end
  end
end

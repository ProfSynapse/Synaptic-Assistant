# lib/assistant/auth/oauth.ex — Google OAuth2 URL builder, code exchange, and stateless token refresh.
#
# Handles the OAuth2 authorization code flow with PKCE (S256) and HMAC-signed
# state parameters. Token exchange uses Req (existing dep). Token refresh uses
# Goth.Token.fetch/1 stateless API (no per-user GenServer process).
#
# Related files:
#   - lib/assistant/auth/token_store.ex (persists tokens after exchange)
#   - lib/assistant/auth/magic_link.ex (generates magic links that start the flow)
#   - lib/assistant_web/controllers/oauth_controller.ex (callback handler)
#   - config/runtime.exs (GOOGLE_OAUTH_CLIENT_ID, GOOGLE_OAUTH_CLIENT_SECRET)

defmodule Assistant.Auth.OAuth do
  @moduledoc """
  Google OAuth2 authorization code flow with PKCE and stateless token refresh.

  ## Authorization URL

  Builds Google OAuth2 consent URLs with:
  - PKCE S256 challenge (RFC 7636)
  - HMAC-SHA256 signed state parameter binding user_id + channel + token_hash + timestamp

  ## Token Exchange

  Exchanges authorization codes for access + refresh tokens via Google's token
  endpoint using Req.

  ## Token Refresh

  Refreshes expired access tokens statelessly via `Goth.Token.fetch/1` with the
  `{:refresh_token, credentials}` source. No per-user process needed.
  """

  require Logger

  @google_auth_url "https://accounts.google.com/o/oauth2/v2/auth"
  @google_token_url "https://oauth2.googleapis.com/token"

  @doc """
  OAuth2 scopes requested for per-user authorization.

  Excludes `chat.bot` (that stays on the service account).
  Includes `openid`, `email`, `profile` for ID token claims.
  """
  @spec user_scopes() :: [String.t()]
  def user_scopes do
    [
      "openid",
      "email",
      "profile",
      "https://www.googleapis.com/auth/drive.readonly",
      "https://www.googleapis.com/auth/drive.file",
      "https://www.googleapis.com/auth/gmail.modify",
      "https://www.googleapis.com/auth/calendar"
    ]
  end

  # --- Authorization URL ---

  @doc """
  Build a Google OAuth2 authorization URL with PKCE S256 and HMAC-signed state.

  ## Parameters

    * `user_id` - The internal user UUID initiating the flow
    * `opts` - Keyword list:
      * `:channel` - The channel the user is chatting from (e.g., "google_chat")
      * `:token_hash` - SHA-256 hash of the magic link token (binds state to magic link)
      * `:code_verifier` - PKCE code verifier (generated if not provided)

  ## Returns

    `{:ok, %{url: String.t(), code_verifier: String.t()}}` or `{:error, reason}`
  """
  @spec build_authorization_url(binary(), keyword()) ::
          {:ok, %{url: String.t(), code_verifier: String.t()}} | {:error, term()}
  def build_authorization_url(user_id, opts \\ []) do
    with {:ok, client_id} <- fetch_client_id(),
         {:ok, redirect_uri} <- build_redirect_uri() do
      channel = Keyword.get(opts, :channel, "unknown")
      token_hash = Keyword.get(opts, :token_hash, "")
      code_verifier = Keyword.get(opts, :code_verifier, generate_code_verifier())
      code_challenge = generate_code_challenge(code_verifier)
      state = sign_state(user_id, channel, token_hash)

      params =
        URI.encode_query(%{
          "client_id" => client_id,
          "redirect_uri" => redirect_uri,
          "response_type" => "code",
          "scope" => Enum.join(user_scopes(), " "),
          "access_type" => "offline",
          "prompt" => "consent",
          "state" => state,
          "code_challenge" => code_challenge,
          "code_challenge_method" => "S256"
        })

      url = "#{@google_auth_url}?#{params}"
      {:ok, %{url: url, code_verifier: code_verifier}}
    end
  end

  # --- Token Exchange ---

  @doc """
  Exchange an authorization code for tokens via Google's token endpoint.

  ## Parameters

    * `code` - The authorization code from Google's callback
    * `code_verifier` - The PKCE code verifier used when building the auth URL

  ## Returns

    `{:ok, token_data}` where `token_data` is a map with keys:
    - `"access_token"` - The access token string
    - `"refresh_token"` - The refresh token string (only on first authorization)
    - `"expires_in"` - Seconds until access token expires
    - `"id_token"` - JWT with user info claims (email, sub, etc.)
    - `"scope"` - Space-delimited granted scopes
    - `"token_type"` - Always "Bearer"

    `{:error, reason}` on failure.
  """
  @spec exchange_code(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def exchange_code(code, code_verifier) do
    with {:ok, client_id} <- fetch_client_id(),
         {:ok, client_secret} <- fetch_client_secret(),
         {:ok, redirect_uri} <- build_redirect_uri() do
      body = %{
        "code" => code,
        "client_id" => client_id,
        "client_secret" => client_secret,
        "redirect_uri" => redirect_uri,
        "grant_type" => "authorization_code",
        "code_verifier" => code_verifier
      }

      case Req.post(@google_token_url, form: body) do
        {:ok, %Req.Response{status: 200, body: token_data}} ->
          Logger.info("OAuth token exchange succeeded",
            scopes: token_data["scope"],
            has_refresh_token: is_binary(token_data["refresh_token"])
          )

          {:ok, token_data}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.error("OAuth token exchange failed",
            status: status,
            error: body["error"],
            description: body["error_description"]
          )

          {:error, {:token_exchange_failed, status, body["error"]}}

        {:error, exception} ->
          Logger.error("OAuth token exchange HTTP error",
            error: inspect(exception)
          )

          {:error, {:http_error, exception}}
      end
    end
  end

  # --- Token Refresh ---

  @doc """
  Refresh an expired access token using a stored refresh token.

  Uses Goth.Token.fetch/1 statelessly — no per-user GenServer process needed.

  ## Parameters

    * `refresh_token` - The decrypted refresh token string

  ## Returns

    `{:ok, %{access_token: String.t(), expires_at: DateTime.t()}}` on success.
    `{:error, :invalid_grant}` if the refresh token has been revoked.
    `{:error, term()}` on other failures.
  """
  @spec refresh_token(String.t()) ::
          {:ok, %{access_token: String.t(), expires_at: DateTime.t()}} | {:error, term()}
  def refresh_token(refresh_token) do
    with {:ok, client_id} <- fetch_client_id(),
         {:ok, client_secret} <- fetch_client_secret() do
      credentials = %{
        "client_id" => client_id,
        "client_secret" => client_secret,
        "refresh_token" => refresh_token
      }

      case Goth.Token.fetch(source: {:refresh_token, credentials}) do
        {:ok, %{token: access_token, expires: expires_unix}} ->
          expires_at = DateTime.from_unix!(expires_unix)

          Logger.info("OAuth token refresh succeeded",
            expires_at: DateTime.to_iso8601(expires_at)
          )

          {:ok, %{access_token: access_token, expires_at: expires_at}}

        {:error, %{body: body}} when is_map(body) ->
          handle_refresh_error(body)

        {:error, reason} ->
          Logger.error("OAuth token refresh failed", error: inspect(reason))
          {:error, {:refresh_failed, reason}}
      end
    end
  end

  # --- State Parameter (HMAC-signed CSRF protection) ---

  @doc """
  Verify and decode an HMAC-signed state parameter from the OAuth callback.

  ## Parameters

    * `state` - The state parameter from Google's callback

  ## Returns

    `{:ok, %{user_id: String.t(), channel: String.t(), token_hash: String.t()}}` or
    `{:error, :invalid_state}` if the HMAC check fails or the state has expired.
  """
  @spec verify_state(String.t()) ::
          {:ok, %{user_id: String.t(), channel: String.t(), token_hash: String.t()}}
          | {:error, :invalid_state}
  def verify_state(state) do
    case Base.url_decode64(state, padding: false) do
      {:ok, decoded} ->
        parse_and_verify_state(decoded)

      :error ->
        {:error, :invalid_state}
    end
  end

  # --- PKCE Helpers ---

  @doc """
  Generate a cryptographically random PKCE code verifier (32 bytes, base64url).
  """
  @spec generate_code_verifier() :: String.t()
  def generate_code_verifier do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Compute the PKCE S256 code challenge from a code verifier.
  """
  @spec generate_code_challenge(String.t()) :: String.t()
  def generate_code_challenge(verifier) do
    :crypto.hash(:sha256, verifier)
    |> Base.url_encode64(padding: false)
  end

  # --- Private Helpers ---

  # State format: "user_id|channel|token_hash|timestamp|hmac"
  # HMAC covers "user_id|channel|token_hash|timestamp"
  # State TTL: 15 minutes (slightly longer than magic link TTL to avoid race)
  @state_ttl_seconds 15 * 60

  defp sign_state(user_id, channel, token_hash) do
    timestamp = System.system_time(:second) |> Integer.to_string()
    payload = "#{user_id}|#{channel}|#{token_hash}|#{timestamp}"
    hmac = compute_hmac(payload)
    signed = "#{payload}|#{hmac}"
    Base.url_encode64(signed, padding: false)
  end

  defp parse_and_verify_state(decoded) do
    case String.split(decoded, "|") do
      [user_id, channel, token_hash, timestamp_str, received_hmac] ->
        payload = "#{user_id}|#{channel}|#{token_hash}|#{timestamp_str}"
        expected_hmac = compute_hmac(payload)

        with true <- Plug.Crypto.secure_compare(received_hmac, expected_hmac),
             {timestamp, ""} <- Integer.parse(timestamp_str),
             true <- System.system_time(:second) - timestamp < @state_ttl_seconds do
          {:ok, %{user_id: user_id, channel: channel, token_hash: token_hash}}
        else
          _ -> {:error, :invalid_state}
        end

      _ ->
        {:error, :invalid_state}
    end
  end

  defp compute_hmac(payload) do
    secret = fetch_secret_key_base!()

    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.url_encode64(padding: false)
  end

  defp handle_refresh_error(%{"error" => "invalid_grant"} = body) do
    Logger.warning("OAuth refresh token revoked or expired",
      description: body["error_description"]
    )

    {:error, :invalid_grant}
  end

  defp handle_refresh_error(body) do
    Logger.error("OAuth token refresh failed",
      error: body["error"],
      description: body["error_description"]
    )

    {:error, {:refresh_failed, body["error"]}}
  end

  defp fetch_client_id do
    case Application.get_env(:assistant, :google_oauth_client_id) do
      nil -> {:error, :missing_google_oauth_client_id}
      id -> {:ok, id}
    end
  end

  defp fetch_client_secret do
    case Application.get_env(:assistant, :google_oauth_client_secret) do
      nil -> {:error, :missing_google_oauth_client_secret}
      secret -> {:ok, secret}
    end
  end

  defp build_redirect_uri do
    case Application.get_env(:assistant, AssistantWeb.Endpoint)[:url][:host] do
      nil -> {:error, :missing_phx_host}
      host -> {:ok, "https://#{host}/auth/google/callback"}
    end
  end

  defp fetch_secret_key_base! do
    Application.get_env(:assistant, AssistantWeb.Endpoint)[:secret_key_base] ||
      raise "SECRET_KEY_BASE not configured"
  end
end

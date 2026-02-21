# lib/assistant_web/controllers/oauth_controller.ex — Per-user Google OAuth callback handler.
#
# Handles the two endpoints of the per-user OAuth2 authorization flow:
#
#   GET /auth/google/start?token=<magic_link_token>
#     — Consumes the magic link token (single-use, time-limited), extracts
#       the stored authorization URL, and redirects the user to Google.
#
#   GET /auth/google/callback?code=<code>&state=<state>
#     — Verifies the HMAC-signed state parameter, exchanges the authorization
#       code for tokens using PKCE, stores the tokens (encrypted), and enqueues
#       replay of the user's original command.
#
# This controller does NOT use CSRF protection because:
#   - /start is initiated via a magic link (clicked from chat, not a browser form)
#   - /callback receives a redirect from Google (no CSRF token available)
#
# Security is provided by:
#   - Single-use magic link tokens (32-byte random, SHA-256 hashed, atomic consume)
#   - PKCE S256 code challenge (prevents authorization code interception)
#   - HMAC-signed state parameter (prevents CSRF on callback, 10-min TTL)
#   - 10-minute magic link expiry
#
# Related files:
#   - lib/assistant/auth/magic_link.ex (magic link lifecycle)
#   - lib/assistant/auth/oauth.ex (PKCE, state HMAC, code exchange, token refresh)
#   - lib/assistant/auth/token_store.ex (encrypted token CRUD)
#   - lib/assistant_web/router.ex (routes: /auth/google/start, /auth/google/callback)

defmodule AssistantWeb.OAuthController do
  use AssistantWeb, :controller

  alias Assistant.Auth.MagicLink
  alias Assistant.Auth.OAuth
  alias Assistant.Auth.TokenStore

  require Logger

  # --- Actions ---

  @doc """
  Initiates the per-user Google OAuth flow.

  Expects a `token` query parameter containing the raw magic link token.
  Consumes the token (single-use), retrieves the stored authorization URL,
  and redirects the user to Google's consent screen.

  ## Query Parameters

    - `token` — the raw magic link token (from the chat message URL)

  ## Responses

    - 302 redirect to Google authorization URL on success
    - 400 with error text for missing/invalid/expired/used tokens
  """
  def start(conn, %{"token" => raw_token}) when is_binary(raw_token) and raw_token != "" do
    case MagicLink.consume(raw_token) do
      {:ok, auth_token} ->
        Logger.info("OAuth start: magic link consumed",
          auth_token_id: auth_token.id,
          user_id: auth_token.user_id
        )

        # Build the authorization URL using the STORED code_verifier from the
        # auth_token. We must derive the code_challenge from the same verifier
        # that will be used in the callback's code exchange — otherwise Google
        # will reject the PKCE verification.
        case build_authorize_url(auth_token, raw_token) do
          {:ok, url} ->
            redirect(conn, external: url)

          {:error, reason} ->
            Logger.error("OAuth start: failed to build authorize URL",
              reason: inspect(reason),
              auth_token_id: auth_token.id
            )

            conn
            |> put_status(500)
            |> text("Failed to initiate Google authorization. Please try again.")
        end

      {:error, :not_found} ->
        Logger.warning("OAuth start: token not found")
        error_response(conn, 400, "Invalid or unknown authorization link.")

      {:error, :expired} ->
        Logger.warning("OAuth start: token expired")

        error_response(
          conn,
          400,
          "This authorization link has expired. Please request a new one."
        )

      {:error, :already_used} ->
        Logger.warning("OAuth start: token already used")
        error_response(conn, 400, "This authorization link has already been used.")
    end
  end

  def start(conn, _params) do
    error_response(conn, 400, "Missing authorization token.")
  end

  @doc """
  Handles the Google OAuth callback after user consent.

  Verifies the HMAC-signed state parameter, exchanges the authorization code
  for tokens using PKCE, decodes the ID token for user claims, stores the
  tokens encrypted in the database, and enqueues replay of the user's
  original command (pending intent).

  ## Query Parameters

    - `code` — the authorization code from Google
    - `state` — the HMAC-signed state parameter (contains user_id, channel, token_hash)

  ## Responses

    - 200 with success HTML on successful token exchange
    - 200 with error HTML if the user denied consent
    - 400/500 with error text for other failures
  """
  def callback(conn, %{"code" => code, "state" => state}) do
    with {:ok, state_data} <- OAuth.verify_state(state),
         {:ok, auth_token} <- lookup_auth_token(state_data.token_hash),
         {:ok, token_data} <- OAuth.exchange_code(code, auth_token.code_verifier),
         {:ok, claims} <- extract_claims(token_data),
         {:ok, _oauth_token} <- store_tokens(state_data.user_id, token_data, claims) do
      Logger.info("OAuth callback: tokens stored successfully",
        user_id: state_data.user_id,
        provider_email: claims["email"]
      )

      # Best-effort: bridge settings_user to chat user via matching email.
      # If a settings_user exists with the same email as the Google account,
      # link them to the chat user so the settings dashboard can access
      # their OAuth tokens and connected drives.
      maybe_link_settings_user(state_data.user_id, claims["email"])

      # Enqueue replay of the user's original command if a pending intent exists
      maybe_enqueue_replay(auth_token)

      html_body =
        if state_data.channel == "settings",
          do: popup_close_html(claims["email"]),
          else: success_html(claims["email"])

      conn
      |> put_status(200)
      |> html(html_body)
    else
      {:error, :invalid_state} ->
        Logger.warning("OAuth callback: invalid state parameter")
        error_response(conn, 400, "Invalid authorization state. The link may have expired.")

      {:error, :auth_token_not_found} ->
        Logger.warning("OAuth callback: auth token not found for state token_hash")
        error_response(conn, 400, "Authorization session not found. Please try again.")

      {:error, {:token_exchange_failed, status, body}} ->
        Logger.error("OAuth callback: token exchange failed",
          status: status,
          error: inspect(body["error"])
        )

        error_response(conn, 500, "Failed to exchange authorization code. Please try again.")

      {:error, {:token_exchange_http_error, reason}} ->
        Logger.error("OAuth callback: token exchange HTTP error", reason: inspect(reason))
        error_response(conn, 500, "Failed to contact Google. Please try again.")

      {:error, :invalid_id_token} ->
        Logger.error("OAuth callback: failed to decode ID token")
        error_response(conn, 500, "Failed to verify your Google identity. Please try again.")

      {:error, :missing_claims} ->
        Logger.error("OAuth callback: ID token missing required claims")
        error_response(conn, 500, "Google did not provide required account information.")

      {:error, reason} ->
        Logger.error("OAuth callback: unexpected error", reason: inspect(reason))
        error_response(conn, 500, "An unexpected error occurred. Please try again.")
    end
  end

  # User denied consent on Google's consent screen
  def callback(conn, %{"error" => error}) do
    Logger.info("OAuth callback: user denied consent", error: error)

    conn
    |> put_status(200)
    |> html(denied_html())
  end

  # Fallback for unexpected callback parameters
  def callback(conn, _params) do
    error_response(conn, 400, "Invalid callback parameters.")
  end

  # --- Private Helpers ---

  @google_authorize_url "https://accounts.google.com/o/oauth2/v2/auth"

  # Builds the Google authorization URL using the STORED code_verifier from
  # the auth_token. We call OAuth.authorize_url/3 to get a properly signed
  # state parameter, then replace the code_challenge with one derived from
  # the stored code_verifier (so PKCE verification succeeds in the callback).
  defp build_authorize_url(auth_token, raw_token) do
    token_hash = MagicLink.hash_token(raw_token)
    channel = extract_channel(auth_token)

    case OAuth.authorize_url(auth_token.user_id, channel, token_hash) do
      {:ok, generated_url, _new_pkce} ->
        # Derive code_challenge from the STORED code_verifier
        code_challenge =
          :crypto.hash(:sha256, auth_token.code_verifier)
          |> Base.url_encode64(padding: false)

        # Parse the generated URL and replace the code_challenge
        %URI{query: query_string} = URI.parse(generated_url)

        corrected_query =
          query_string
          |> URI.decode_query()
          |> Map.put("code_challenge", code_challenge)
          |> URI.encode_query()

        {:ok, "#{@google_authorize_url}?#{corrected_query}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_channel(auth_token) do
    case auth_token.pending_intent do
      %{"channel" => channel} when is_binary(channel) -> channel
      _ -> "unknown"
    end
  end

  defp lookup_auth_token(token_hash) do
    import Ecto.Query

    case Assistant.Repo.one(
           from(t in Assistant.Schemas.AuthToken,
             where: t.token_hash == ^token_hash
           )
         ) do
      nil -> {:error, :auth_token_not_found}
      auth_token -> {:ok, auth_token}
    end
  end

  defp extract_claims(token_data) do
    case token_data do
      %{"id_token" => id_token} when is_binary(id_token) ->
        case OAuth.decode_id_token(id_token) do
          {:ok, %{"email" => _email, "sub" => _sub} = claims} ->
            {:ok, claims}

          {:ok, _claims_without_required} ->
            {:error, :missing_claims}

          error ->
            error
        end

      _ ->
        {:error, :missing_claims}
    end
  end

  defp store_tokens(user_id, token_data, claims) do
    expires_at =
      case token_data["expires_in"] do
        seconds when is_integer(seconds) and seconds > 0 ->
          DateTime.add(DateTime.utc_now(), seconds, :second)

        _ ->
          nil
      end

    TokenStore.upsert_google_token(user_id, %{
      refresh_token: token_data["refresh_token"],
      access_token: token_data["access_token"],
      token_expires_at: expires_at,
      provider_email: claims["email"],
      provider_uid: claims["sub"],
      scopes: token_data["scope"]
    })
  end

  # Best-effort bridge: if a settings_user has the same email as the Google
  # account that just authorized, link them to the chat user so the settings
  # dashboard can access their OAuth tokens and connected drives.
  defp maybe_link_settings_user(chat_user_id, provider_email)
       when is_binary(chat_user_id) and is_binary(provider_email) do
    case Assistant.Repo.get_by(Assistant.Accounts.SettingsUser, email: provider_email) do
      %{user_id: nil} = settings_user ->
        settings_user
        |> Ecto.Changeset.change(user_id: chat_user_id)
        |> Assistant.Repo.update()
        |> case do
          {:ok, _} ->
            Logger.info("OAuth callback: linked settings_user to chat user",
              provider_email: provider_email,
              chat_user_id: chat_user_id
            )

          {:error, changeset} ->
            Logger.warning("OAuth callback: failed to link settings_user",
              provider_email: provider_email,
              errors: inspect(changeset.errors)
            )
        end

      %{user_id: _existing_user_id} ->
        # Already linked, nothing to do
        :ok

      nil ->
        # No settings_user with this email, nothing to do
        :ok
    end
  end

  defp maybe_link_settings_user(_chat_user_id, _provider_email), do: :ok

  defp maybe_enqueue_replay(auth_token) do
    case auth_token.pending_intent do
      %{} = intent when map_size(intent) > 0 ->
        Logger.info("OAuth callback: enqueuing pending intent replay",
          auth_token_id: auth_token.id,
          user_id: auth_token.user_id
        )

        args =
          %{
            user_id: auth_token.user_id,
            message: intent["message"],
            conversation_id: intent["conversation_id"],
            channel: intent["channel"],
            reply_context: intent["reply_context"]
          }
          |> maybe_put_mode(intent)

        args
        |> Assistant.Workers.PendingIntentWorker.new()
        |> Oban.insert()

      _ ->
        Logger.info("OAuth callback: no pending intent to replay",
          auth_token_id: auth_token.id
        )

        :ok
    end
  end

  # Include mode in worker args if present in the pending intent.
  # Defaults to nil (worker falls back to :multi_agent).
  defp maybe_put_mode(args, %{"mode" => mode}) when is_binary(mode),
    do: Map.put(args, :mode, mode)

  defp maybe_put_mode(args, _intent), do: args

  defp error_response(conn, status, message) do
    conn
    |> put_status(status)
    |> text(message)
  end

  # --- HTML Templates ---
  # Inline HTML for the OAuth result pages. These are simple one-off pages
  # that the user sees briefly in their browser after the OAuth flow.
  # They don't warrant full Phoenix templates/layouts.

  defp popup_close_html(email) do
    ~s"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Google Account Connected</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
               display: flex; justify-content: center; align-items: center; min-height: 100vh;
               margin: 0; background: #f8f9fa; color: #333; }
        .card { background: white; border-radius: 12px; padding: 2rem; max-width: 400px;
                text-align: center; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
        .icon { font-size: 3rem; margin-bottom: 1rem; }
        h1 { font-size: 1.25rem; margin: 0 0 0.5rem; }
        p { color: #666; margin: 0; font-size: 0.9rem; }
        .email { font-weight: 600; color: #333; }
      </style>
    </head>
    <body>
      <div class="card">
        <div class="icon">&#10004;&#65039;</div>
        <h1>Google Account Connected</h1>
        <p>Signed in as <span class="email">#{html_escape(email || "your Google account")}</span>.</p>
        <p style="margin-top: 1rem;">This window will close automatically...</p>
      </div>
      <script>
        // Brief delay so the user sees the success message before the popup closes.
        setTimeout(function() { window.close(); }, 1500);
      </script>
    </body>
    </html>
    """
  end

  defp success_html(email) do
    ~s"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Google Account Connected</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
               display: flex; justify-content: center; align-items: center; min-height: 100vh;
               margin: 0; background: #f8f9fa; color: #333; }
        .card { background: white; border-radius: 12px; padding: 2rem; max-width: 400px;
                text-align: center; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
        .icon { font-size: 3rem; margin-bottom: 1rem; }
        h1 { font-size: 1.25rem; margin: 0 0 0.5rem; }
        p { color: #666; margin: 0; font-size: 0.9rem; }
        .email { font-weight: 600; color: #333; }
      </style>
    </head>
    <body>
      <div class="card">
        <div class="icon">&#10004;&#65039;</div>
        <h1>Google Account Connected</h1>
        <p>Signed in as <span class="email">#{html_escape(email || "your Google account")}</span>.</p>
        <p style="margin-top: 1rem;">You can close this window and return to the chat.</p>
      </div>
    </body>
    </html>
    """
  end

  defp denied_html do
    ~s"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Authorization Cancelled</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
               display: flex; justify-content: center; align-items: center; min-height: 100vh;
               margin: 0; background: #f8f9fa; color: #333; }
        .card { background: white; border-radius: 12px; padding: 2rem; max-width: 400px;
                text-align: center; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
        .icon { font-size: 3rem; margin-bottom: 1rem; }
        h1 { font-size: 1.25rem; margin: 0 0 0.5rem; }
        p { color: #666; margin: 0; font-size: 0.9rem; }
      </style>
    </head>
    <body>
      <div class="card">
        <div class="icon">&#128683;</div>
        <h1>Authorization Cancelled</h1>
        <p>You did not grant access to your Google account.</p>
        <p style="margin-top: 1rem;">You can close this window. To try again, use the connect command in the chat.</p>
      </div>
    </body>
    </html>
    """
  end

  defp html_escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#039;")
  end

  defp html_escape(_), do: ""
end

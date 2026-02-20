# lib/assistant_web/controllers/oauth_controller.ex — OAuth2 browser-facing controller.
#
# Handles the two endpoints that constitute the browser side of the OAuth2 flow:
#   GET /auth/google/start?token=MAGIC_LINK_TOKEN  — validates magic link, redirects to Google
#   GET /auth/google/callback?code=CODE&state=STATE — exchanges code, stores tokens, triggers replay
#
# PKCE code_verifiers are stored in the auth_tokens DB table (code_verifier column)
# alongside the magic link token. This survives process restarts and multi-node deploys.
#
# Related files:
#   - lib/assistant/auth/magic_link.ex (validate/consume magic link tokens)
#   - lib/assistant/auth/oauth.ex (URL builder, token exchange, state verification)
#   - lib/assistant/auth/token_store.ex (persist tokens after exchange)
#   - lib/assistant/workers/pending_intent_worker.ex (Oban job rescheduled on success)
#   - lib/assistant_web/router.ex (route definitions)

defmodule AssistantWeb.OAuthController do
  @moduledoc """
  Controller for the Google OAuth2 authorization code flow.

  ## Endpoints

    * `GET /auth/google/start?token=<magic_link_token>` — Entry point. Validates
      the magic link token, builds a Google OAuth2 consent URL with PKCE, stores
      the code verifier in the auth_tokens DB row, and redirects the user to Google.

    * `GET /auth/google/callback?code=<code>&state=<state>` — Callback from Google.
      Verifies the HMAC-signed state, retrieves the PKCE code verifier from the DB,
      exchanges the authorization code for tokens, stores them encrypted in the
      database, consumes the magic link, reschedules the PendingIntentWorker, and
      renders a success page.

  ## Security Properties

    * PKCE S256 prevents authorization code interception
    * HMAC-signed state prevents CSRF (binds to user_id, channel, token_hash)
    * Magic link consumed atomically (single-use)
    * No sensitive data in success page HTML
    * Generic error messages — do not reveal failure reasons to the browser
  """

  use AssistantWeb, :controller

  import Ecto.Query

  alias Assistant.Auth.MagicLink
  alias Assistant.Auth.OAuth
  alias Assistant.Auth.TokenStore
  alias Assistant.Schemas.AuthToken

  require Logger

  # --- Actions ---

  @doc """
  Start the OAuth flow. Validates the magic link token, builds Google OAuth URL,
  stores the PKCE code_verifier on the auth_token DB row, and redirects to Google.
  """
  def start(conn, %{"token" => raw_token}) do
    with {:ok, %{user_id: user_id}} <- MagicLink.validate(raw_token),
         token_hash <- hash_token(raw_token),
         channel <- "browser",
         {:ok, %{url: url, code_verifier: code_verifier}} <-
           OAuth.build_authorization_url(user_id,
             channel: channel,
             token_hash: token_hash
           ),
         :ok <- store_code_verifier(token_hash, code_verifier) do
      Logger.info("OAuth flow started, redirecting to Google",
        user_id: user_id
      )

      redirect(conn, external: url)
    else
      {:error, reason} ->
        Logger.warning("OAuth start failed", reason: inspect(reason))
        render_error(conn, "This link is invalid or has expired. Please request a new one.")
    end
  end

  def start(conn, _params) do
    render_error(conn, "This link is invalid or has expired. Please request a new one.")
  end

  @doc """
  Handle the OAuth callback from Google. Verifies state, exchanges code for tokens,
  stores them, consumes the magic link, and reschedules the PendingIntentWorker.
  """
  def callback(conn, %{"code" => code, "state" => state}) do
    with {:ok, %{user_id: user_id, token_hash: token_hash}} <- OAuth.verify_state(state),
         {:ok, auth_token} <- fetch_auth_token_by_hash(token_hash),
         {:ok, token_data} <- OAuth.exchange_code(code, auth_token.code_verifier),
         {:ok, claims} <- decode_id_token(token_data["id_token"]),
         {:ok, _oauth_token} <- store_tokens(user_id, token_data, claims),
         {:ok, consumed_token} <- MagicLink.consume_by_hash(token_hash) do
      maybe_reschedule_pending_intent(consumed_token.oban_job_id)

      provider_email = claims["email"] || "your account"

      Logger.info("OAuth flow completed successfully",
        user_id: user_id,
        provider_email: provider_email
      )

      render_success(conn, provider_email)
    else
      {:error, reason} ->
        Logger.warning("OAuth callback failed", reason: inspect(reason))
        render_error(conn, "Authorization failed. Please try again by requesting a new link.")
    end
  end

  def callback(conn, %{"error" => error}) do
    Logger.warning("OAuth callback received error from Google", error: error)
    render_error(conn, "Authorization was denied or cancelled. You can close this tab.")
  end

  def callback(conn, _params) do
    render_error(conn, "Authorization failed. Please try again by requesting a new link.")
  end

  # --- PKCE DB Storage ---
  # code_verifier is stored on the auth_tokens row (same row as the magic link).
  # This replaces the previous ETS-based storage for durability.

  defp store_code_verifier(token_hash, code_verifier) do
    case from(t in AuthToken, where: t.token_hash == ^token_hash and is_nil(t.used_at))
         |> Assistant.Repo.update_all(set: [code_verifier: code_verifier]) do
      {1, _} -> :ok
      {0, _} -> {:error, :auth_token_not_found}
    end
  end

  defp fetch_auth_token_by_hash(token_hash) do
    case Assistant.Repo.one(
           from(t in AuthToken,
             where: t.token_hash == ^token_hash and is_nil(t.used_at) and not is_nil(t.code_verifier)
           )
         ) do
      nil -> {:error, :pkce_not_found}
      %AuthToken{} = auth_token -> {:ok, auth_token}
    end
  end

  # --- Token Storage ---

  defp store_tokens(user_id, token_data, claims) do
    expires_at =
      case token_data["expires_in"] do
        seconds when is_integer(seconds) ->
          DateTime.add(DateTime.utc_now(), seconds, :second)

        _ ->
          nil
      end

    attrs = %{
      user_id: user_id,
      provider: "google",
      refresh_token: token_data["refresh_token"],
      access_token: token_data["access_token"],
      token_expires_at: expires_at,
      provider_uid: claims["sub"],
      provider_email: claims["email"],
      scopes: token_data["scope"]
    }

    TokenStore.upsert_token(attrs)
  end

  # --- ID Token Decoding ---

  # Decode the Google ID token (JWT) to extract user claims.
  # We trust the token since we received it directly from Google's token endpoint
  # over HTTPS — no signature verification needed here.
  defp decode_id_token(nil), do: {:ok, %{}}

  defp decode_id_token(id_token) when is_binary(id_token) do
    case String.split(id_token, ".") do
      [_header, payload, _signature] ->
        case Base.url_decode64(payload, padding: false) do
          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, claims} ->
                {:ok, claims}

              {:error, reason} ->
                Logger.warning("Failed to decode id_token JSON payload",
                  reason: inspect(reason)
                )

                {:ok, %{}}
            end

          :error ->
            Logger.warning("Failed to base64-decode id_token payload")
            {:ok, %{}}
        end

      _ ->
        Logger.warning("Malformed id_token: expected 3 dot-separated segments")
        {:ok, %{}}
    end
  end

  # --- PendingIntentWorker Rescheduling ---

  defp maybe_reschedule_pending_intent(nil), do: :ok

  defp maybe_reschedule_pending_intent(oban_job_id) when is_integer(oban_job_id) do
    case Oban.Job
         |> Assistant.Repo.get(oban_job_id) do
      nil ->
        Logger.warning("PendingIntentWorker job not found for rescheduling",
          oban_job_id: oban_job_id
        )

      %Oban.Job{state: "scheduled"} = job ->
        # Reschedule from far-future to now
        job
        |> Ecto.Changeset.change(scheduled_at: DateTime.utc_now())
        |> Assistant.Repo.update()

        Logger.info("PendingIntentWorker rescheduled to run now",
          oban_job_id: oban_job_id
        )

      %Oban.Job{state: state} ->
        Logger.warning("PendingIntentWorker job in unexpected state",
          oban_job_id: oban_job_id,
          state: state
        )
    end
  end

  # --- Helpers ---

  defp hash_token(raw_token), do: MagicLink.hash_token(raw_token)

  # --- HTML Rendering ---

  defp render_success(conn, provider_email) do
    html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Connected</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
               display: flex; justify-content: center; align-items: center; min-height: 100vh;
               margin: 0; background: #f5f5f5; color: #333; }
        .card { background: white; border-radius: 12px; padding: 2rem; max-width: 400px;
                text-align: center; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
        .check { font-size: 3rem; margin-bottom: 1rem; }
        h1 { font-size: 1.25rem; margin: 0 0 0.5rem; }
        p { color: #666; margin: 0; font-size: 0.9rem; }
        .email { font-weight: 600; color: #333; }
      </style>
    </head>
    <body>
      <div class="card">
        <div class="check">&#10003;</div>
        <h1>Google Account Connected</h1>
        <p>Connected as <span class="email">#{html_escape(provider_email)}</span></p>
        <p style="margin-top: 1rem;">You can close this tab. Your request is being processed.</p>
      </div>
    </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  defp render_error(conn, message) do
    html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Error</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
               display: flex; justify-content: center; align-items: center; min-height: 100vh;
               margin: 0; background: #f5f5f5; color: #333; }
        .card { background: white; border-radius: 12px; padding: 2rem; max-width: 400px;
                text-align: center; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
        .icon { font-size: 3rem; margin-bottom: 1rem; }
        h1 { font-size: 1.25rem; margin: 0 0 0.5rem; }
        p { color: #666; margin: 0; font-size: 0.9rem; }
      </style>
    </head>
    <body>
      <div class="card">
        <div class="icon">&#10007;</div>
        <h1>Authorization Error</h1>
        <p>#{html_escape(message)}</p>
      </div>
    </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(400, html)
  end

  defp html_escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end

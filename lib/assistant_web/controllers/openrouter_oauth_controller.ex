# lib/assistant_web/controllers/openrouter_oauth_controller.ex
#
# Handles the OpenRouter PKCE OAuth connect/disconnect flow for settings_users.
# Users initiate the flow from the settings page; on success, an encrypted API key
# is stored on the settings_user record.
#
# OpenRouter uses a non-standard OAuth flow:
#   - Authorization: GET https://openrouter.ai/auth with PKCE S256 challenge
#   - Code exchange: POST https://openrouter.ai/api/v1/auth/keys (returns permanent API key)
#   - No refresh tokens, no expiry, no revocation endpoint
#
# Related files:
#   - lib/assistant/accounts/settings_user.ex (encrypted openrouter_api_key field)
#   - lib/assistant/accounts.ex (save_openrouter_api_key/2, delete_openrouter_api_key/1)
#   - lib/assistant_web/router.ex (route definitions)
#   - config/runtime.exs (OPENROUTER_APP_API_KEY env var)

defmodule AssistantWeb.OpenRouterOAuthController do
  use AssistantWeb, :controller

  alias Assistant.Accounts

  require Logger

  @openrouter_auth_url "https://openrouter.ai/auth"
  @openrouter_keys_url "https://openrouter.ai/api/v1/auth/keys"
  @pkce_verifier_session_key :openrouter_pkce_verifier

  @doc """
  Initiates the OpenRouter PKCE OAuth flow.

  Generates a PKCE code_verifier + S256 challenge, stores the verifier in
  the session, and redirects the user to OpenRouter's authorization page.
  """
  def request(conn, _params) do
    with {:ok, settings_user} <- fetch_settings_user(conn),
         {:ok, _app_key} <- fetch_app_api_key() do
      code_verifier = generate_code_verifier()
      code_challenge = generate_code_challenge(code_verifier)

      params =
        URI.encode_query(%{
          "callback_url" => callback_url(),
          "code_challenge" => code_challenge,
          "code_challenge_method" => "S256"
        })

      Logger.info("OpenRouter OAuth initiated",
        settings_user_id: settings_user.id
      )

      conn
      |> put_session(@pkce_verifier_session_key, code_verifier)
      |> redirect(external: "#{@openrouter_auth_url}?#{params}")
    else
      {:error, :not_authenticated} ->
        conn
        |> put_flash(:error, "You must log in to connect OpenRouter.")
        |> redirect(to: ~p"/settings_users/log-in")

      {:error, :missing_app_api_key} ->
        Logger.warning("OpenRouter OAuth request failed: OPENROUTER_APP_API_KEY not configured")

        conn
        |> put_flash(:error, "OpenRouter integration is not configured.")
        |> redirect(to: ~p"/settings")
    end
  end

  @doc """
  Handles the OpenRouter OAuth callback.

  Retrieves the PKCE verifier from session, exchanges the authorization code
  for a permanent API key, and stores it encrypted on the settings_user.
  """
  def callback(conn, %{"code" => code}) do
    with {:ok, settings_user} <- fetch_settings_user(conn),
         {:ok, _code_verifier} <- fetch_pkce_verifier(conn),
         {:ok, api_key} <- exchange_code_for_key(code),
         {:ok, _settings_user} <- Accounts.save_openrouter_api_key(settings_user, api_key) do
      Logger.info("OpenRouter OAuth connected successfully",
        settings_user_id: settings_user.id
      )

      conn
      |> delete_session(@pkce_verifier_session_key)
      |> put_flash(:info, "OpenRouter connected successfully.")
      |> redirect(to: ~p"/settings")
    else
      {:error, :not_authenticated} ->
        conn
        |> delete_session(@pkce_verifier_session_key)
        |> put_flash(:error, "You must log in to connect OpenRouter.")
        |> redirect(to: ~p"/settings_users/log-in")

      {:error, :missing_pkce_verifier} ->
        Logger.warning("OpenRouter callback failed: PKCE verifier not found in session")

        conn
        |> put_flash(:error, "OpenRouter connection failed. Please try again.")
        |> redirect(to: ~p"/settings")

      {:error, reason} ->
        Logger.warning("OpenRouter OAuth callback failed", reason: inspect(reason))

        conn
        |> delete_session(@pkce_verifier_session_key)
        |> put_flash(:error, "Failed to connect OpenRouter. Please try again.")
        |> redirect(to: ~p"/settings")
    end
  end

  def callback(conn, _params) do
    conn
    |> delete_session(@pkce_verifier_session_key)
    |> put_flash(:error, "OpenRouter connection was cancelled or failed.")
    |> redirect(to: ~p"/settings")
  end

  @doc """
  Disconnects OpenRouter by removing the stored API key.
  """
  def disconnect(conn, _params) do
    case fetch_settings_user(conn) do
      {:ok, settings_user} ->
        case Accounts.delete_openrouter_api_key(settings_user) do
          {:ok, _settings_user} ->
            Logger.info("OpenRouter disconnected",
              settings_user_id: settings_user.id
            )

            conn
            |> put_flash(:info, "OpenRouter disconnected.")
            |> redirect(to: ~p"/settings")

          {:error, _changeset} ->
            conn
            |> put_flash(:error, "Failed to disconnect OpenRouter.")
            |> redirect(to: ~p"/settings")
        end

      {:error, :not_authenticated} ->
        conn
        |> put_flash(:error, "You must log in to disconnect OpenRouter.")
        |> redirect(to: ~p"/settings_users/log-in")
    end
  end

  # --- Private helpers ---

  defp fetch_settings_user(conn) do
    case conn.assigns[:current_scope] do
      %{settings_user: %Accounts.SettingsUser{} = settings_user} ->
        {:ok, settings_user}

      _ ->
        {:error, :not_authenticated}
    end
  end

  defp fetch_pkce_verifier(conn) do
    case get_session(conn, @pkce_verifier_session_key) do
      verifier when is_binary(verifier) and verifier != "" ->
        {:ok, verifier}

      _ ->
        {:error, :missing_pkce_verifier}
    end
  end

  defp fetch_app_api_key do
    case Application.get_env(:assistant, :openrouter_app_api_key) do
      key when is_binary(key) and key != "" ->
        {:ok, key}

      _ ->
        {:error, :missing_app_api_key}
    end
  end

  defp exchange_code_for_key(code) do
    with {:ok, app_key} <- fetch_app_api_key() do
      case Req.post(@openrouter_keys_url,
             json: %{"code" => code},
             headers: [{"authorization", "Bearer #{app_key}"}]
           ) do
        {:ok, %Req.Response{status: 200, body: %{"key" => key}}} when is_binary(key) ->
          {:ok, key}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:openrouter_key_exchange_failed, status, body}}

        {:error, reason} ->
          {:error, {:openrouter_key_exchange_http_error, reason}}
      end
    end
  end

  defp callback_url, do: url(~p"/settings_users/auth/openrouter/callback")

  defp generate_code_verifier do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  defp generate_code_challenge(verifier) do
    :crypto.hash(:sha256, verifier)
    |> Base.url_encode64(padding: false)
  end
end

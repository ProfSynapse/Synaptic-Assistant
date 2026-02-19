defmodule AssistantWeb.SettingsUserOAuthController do
  use AssistantWeb, :controller

  alias Assistant.Accounts
  alias AssistantWeb.SettingsUserAuth

  require Logger

  @google_authorize_url "https://accounts.google.com/o/oauth2/v2/auth"
  @google_token_url "https://oauth2.googleapis.com/token"
  @google_userinfo_url "https://openidconnect.googleapis.com/v1/userinfo"
  @google_scopes "openid email profile"
  @state_session_key :settings_user_google_oauth_state

  def request(conn, _params) do
    with {:ok, client_id} <- fetch_client_id() do
      state = random_state()

      params =
        URI.encode_query(%{
          "client_id" => client_id,
          "redirect_uri" => callback_url(),
          "response_type" => "code",
          "scope" => @google_scopes,
          "state" => state,
          "access_type" => "online",
          "prompt" => "select_account"
        })

      conn
      |> put_session(@state_session_key, state)
      |> redirect(external: "#{@google_authorize_url}?#{params}")
    else
      {:error, :missing_google_oauth_client_id} ->
        conn
        |> put_flash(:error, "Google sign in is not configured yet.")
        |> redirect(to: ~p"/settings_users/log-in")
    end
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    with :ok <- verify_state(conn, state),
         {:ok, token_data} <- exchange_code(code, callback_url()),
         {:ok, claims} <- fetch_claims(token_data),
         {:ok, settings_user} <- Accounts.get_or_register_settings_user_from_google(claims) do
      conn
      |> delete_session(@state_session_key)
      |> put_flash(:info, "Signed in with Google.")
      |> SettingsUserAuth.log_in_settings_user(settings_user, %{"remember_me" => "true"})
    else
      {:error, reason} ->
        Logger.warning("Google sign in failed", reason: inspect(reason))

        conn
        |> delete_session(@state_session_key)
        |> put_flash(:error, "Google sign in failed. Please try again.")
        |> redirect(to: ~p"/settings_users/log-in")
    end
  end

  def callback(conn, %{"error" => _provider_error}) do
    conn
    |> delete_session(@state_session_key)
    |> put_flash(:error, "Google sign in was cancelled.")
    |> redirect(to: ~p"/settings_users/log-in")
  end

  def callback(conn, _params) do
    conn
    |> delete_session(@state_session_key)
    |> put_flash(:error, "Google sign in failed. Please try again.")
    |> redirect(to: ~p"/settings_users/log-in")
  end

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

  defp callback_url, do: url(~p"/settings_users/auth/google/callback")

  defp verify_state(conn, incoming_state) when is_binary(incoming_state) do
    expected_state = get_session(conn, @state_session_key)

    if is_binary(expected_state) and Plug.Crypto.secure_compare(incoming_state, expected_state) do
      :ok
    else
      {:error, :invalid_oauth_state}
    end
  end

  defp verify_state(_conn, _incoming_state), do: {:error, :invalid_oauth_state}

  defp exchange_code(code, redirect_uri) do
    with {:ok, client_id} <- fetch_client_id(),
         {:ok, client_secret} <- fetch_client_secret() do
      form = %{
        "code" => code,
        "client_id" => client_id,
        "client_secret" => client_secret,
        "redirect_uri" => redirect_uri,
        "grant_type" => "authorization_code"
      }

      case Req.post(@google_token_url, form: form) do
        {:ok, %Req.Response{status: 200, body: %{} = body}} ->
          {:ok, body}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:google_token_exchange_failed, status, body}}

        {:error, reason} ->
          {:error, {:google_token_exchange_http_error, reason}}
      end
    end
  end

  defp fetch_claims(%{"id_token" => id_token} = token_data) when is_binary(id_token) do
    case decode_id_token(id_token) do
      {:ok, %{"email" => _email} = claims} ->
        {:ok, claims}

      _ ->
        fetch_userinfo_claims(token_data["access_token"])
    end
  end

  defp fetch_claims(%{"access_token" => access_token}) when is_binary(access_token) do
    fetch_userinfo_claims(access_token)
  end

  defp fetch_claims(_), do: {:error, :missing_oauth_claims}

  defp fetch_userinfo_claims(access_token) do
    case Req.get(@google_userinfo_url, auth: {:bearer, access_token}) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:google_userinfo_failed, status, body}}

      {:error, reason} ->
        {:error, {:google_userinfo_http_error, reason}}
    end
  end

  defp decode_id_token(id_token) do
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

  defp random_state do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end
end

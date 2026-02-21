defmodule AssistantWeb.OpenAIOAuthController do
  use AssistantWeb, :controller

  alias Assistant.Accounts

  require Logger

  @default_client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @default_authorize_url "https://auth.openai.com/oauth/authorize"
  @default_token_url "https://auth.openai.com/oauth/token"
  @default_issuer "https://auth.openai.com"
  @default_scope "openid profile email offline_access"
  @default_originator "synaptic-assistant"
  @default_oauth_flow "device"

  @state_session_key :openai_oauth_state
  @pkce_verifier_session_key :openai_pkce_verifier
  @popup_session_key :openai_oauth_popup
  @device_auth_id_session_key :openai_device_auth_id
  @device_user_code_session_key :openai_device_user_code
  @device_poll_interval_session_key :openai_device_poll_interval_ms

  @doc """
  Initiates OpenAI OAuth (Authorization Code + PKCE) for an authenticated settings user.
  """
  def request(conn, params) do
    with {:ok, settings_user} <- fetch_settings_user(conn) do
      popup? = popup_request_param?(params)
      flow = oauth_flow(params, popup?)

      Logger.info("OpenAI OAuth request started",
        settings_user_id: settings_user.id,
        popup: popup?,
        flow: flow
      )

      case flow do
        :device ->
          start_device_oauth(conn, settings_user, popup?)

        :browser ->
          start_browser_oauth(conn, settings_user, popup?)
      end
    else
      {:error, :not_authenticated} ->
        conn
        |> put_flash(:error, "You must log in to connect OpenAI.")
        |> redirect(to: ~p"/settings_users/log-in")
    end
  end

  @doc """
  Poll endpoint for OpenAI device authorization flow.
  """
  def device_poll(conn, _params) do
    popup? = popup_request?(conn)

    with {:ok, settings_user} <- fetch_settings_user(conn),
         {:ok, device_auth_id, user_code} <- fetch_device_session(conn),
         {:ok, poll_result} <- poll_device_authorization(device_auth_id, user_code) do
      case poll_result do
        :pending ->
          json(conn, %{status: "pending"})

        {:approved, authorization_code, code_verifier} ->
          with {:ok, tokens} <-
                 exchange_device_code_for_access_token(authorization_code, code_verifier),
               access_token when is_binary(access_token) <- Map.get(tokens, "access_token"),
               {:ok, _} <-
                 Accounts.save_openai_oauth_credentials(
                   settings_user,
                   oauth_attrs_from_tokens(tokens, access_token)
                 ) do
            conn
            |> clear_oauth_session()
            |> json(%{status: "connected", popup: popup?})
          else
            _ ->
              conn
              |> clear_oauth_session()
              |> json(%{status: "error", message: "OpenAI device token exchange failed."})
          end
      end
    else
      {:error, :not_authenticated} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", message: "You must log in to connect OpenAI."})

      {:error, :missing_device_session} ->
        conn
        |> put_status(:bad_request)
        |> json(%{status: "error", message: "OpenAI device authorization is not active."})

      {:error, reason} ->
        Logger.warning("OpenAI device poll failed", reason: inspect(reason))

        conn
        |> put_status(:bad_gateway)
        |> json(%{status: "error", message: "OpenAI device authorization failed."})
    end
  end

  @doc """
  Handles the OpenAI OAuth callback and persists the OAuth access token.
  """
  def callback(conn, %{"code" => code, "state" => state}) do
    popup? = popup_request?(conn)

    with {:ok, settings_user} <- fetch_settings_user(conn),
         :ok <- verify_state(conn, state),
         {:ok, code_verifier} <- fetch_pkce_verifier(conn),
         {:ok, _user_id} <- ensure_linked_user(settings_user),
         {:ok, tokens} <- exchange_code_for_access_token(code, code_verifier),
         access_token when is_binary(access_token) <- Map.get(tokens, "access_token"),
         {:ok, _settings_user} <-
           Accounts.save_openai_oauth_credentials(
             settings_user,
             oauth_attrs_from_tokens(tokens, access_token)
           ) do
      Logger.info("OpenAI OAuth connected successfully", settings_user_id: settings_user.id)

      conn
      |> clear_oauth_session()
      |> finish_callback(popup?, :info, "OpenAI connected successfully.", ~p"/settings")
    else
      {:error, :not_authenticated} ->
        conn
        |> clear_oauth_session()
        |> finish_callback(
          popup?,
          :error,
          "You must log in to connect OpenAI.",
          ~p"/settings_users/log-in"
        )

      {:error, :invalid_oauth_state} ->
        conn
        |> clear_oauth_session()
        |> finish_callback(
          popup?,
          :error,
          "OpenAI connection failed. Please try again.",
          ~p"/settings"
        )

      {:error, :missing_pkce_verifier} ->
        conn
        |> clear_oauth_session()
        |> finish_callback(
          popup?,
          :error,
          "OpenAI connection failed. Please try again.",
          ~p"/settings"
        )

      {:error, reason} ->
        Logger.warning("OpenAI OAuth callback failed", reason: inspect(reason))

        conn
        |> clear_oauth_session()
        |> finish_callback(
          popup?,
          :error,
          "Failed to connect OpenAI. Please try again.",
          ~p"/settings"
        )

      _ ->
        conn
        |> clear_oauth_session()
        |> finish_callback(
          popup?,
          :error,
          "Failed to connect OpenAI. Please try again.",
          ~p"/settings"
        )
    end
  end

  def callback(conn, %{"error" => _provider_error}) do
    popup? = popup_request?(conn)

    conn
    |> clear_oauth_session()
    |> finish_callback(popup?, :error, "OpenAI connection was cancelled.", ~p"/settings")
  end

  def callback(conn, _params) do
    popup? = popup_request?(conn)

    conn
    |> clear_oauth_session()
    |> finish_callback(
      popup?,
      :error,
      "OpenAI connection failed. Please try again.",
      ~p"/settings"
    )
  end

  defp fetch_settings_user(conn) do
    case conn.assigns[:current_scope] do
      %{settings_user: %Accounts.SettingsUser{} = settings_user} ->
        {:ok, settings_user}

      _ ->
        {:error, :not_authenticated}
    end
  end

  defp fetch_client_id,
    do: Application.get_env(:assistant, :openai_oauth_client_id, @default_client_id)

  defp fetch_client_secret do
    case Application.get_env(:assistant, :openai_oauth_client_secret) do
      client_secret when is_binary(client_secret) and client_secret != "" ->
        {:ok, client_secret}

      _ ->
        :none
    end
  end

  defp verify_state(conn, incoming_state) when is_binary(incoming_state) do
    expected_state = get_session(conn, @state_session_key)

    if is_binary(expected_state) and Plug.Crypto.secure_compare(incoming_state, expected_state) do
      :ok
    else
      {:error, :invalid_oauth_state}
    end
  end

  defp verify_state(_conn, _incoming_state), do: {:error, :invalid_oauth_state}

  defp fetch_pkce_verifier(conn) do
    case get_session(conn, @pkce_verifier_session_key) do
      verifier when is_binary(verifier) and verifier != "" ->
        {:ok, verifier}

      _ ->
        {:error, :missing_pkce_verifier}
    end
  end

  defp exchange_code_for_access_token(code, code_verifier) do
    form = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => callback_url(),
      "client_id" => fetch_client_id(),
      "code_verifier" => code_verifier
    }

    form =
      case fetch_client_secret() do
        {:ok, client_secret} -> Map.put(form, "client_secret", client_secret)
        :none -> form
      end

    case Req.post(token_url(), form: form) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => access_token} = body}}
      when is_binary(access_token) and access_token != "" ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:openai_token_exchange_failed, status, body}}

      {:error, reason} ->
        {:error, {:openai_token_exchange_http_error, reason}}
    end
  end

  defp exchange_device_code_for_access_token(code, code_verifier) do
    form = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => "#{oauth_issuer()}/deviceauth/callback",
      "client_id" => fetch_client_id(),
      "code_verifier" => code_verifier
    }

    case Req.post(token_url(), form: form) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => access_token} = body}}
      when is_binary(access_token) and access_token != "" ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:openai_device_token_exchange_failed, status, body}}

      {:error, reason} ->
        {:error, {:openai_device_token_exchange_http_error, reason}}
    end
  end

  defp ensure_linked_user(%{user_id: user_id}) when not is_nil(user_id), do: {:ok, user_id}

  defp ensure_linked_user(settings_user) do
    user_attrs = %{
      external_id: "settings:#{settings_user.id}",
      channel: "settings",
      display_name: settings_user.display_name
    }

    case %Assistant.Schemas.User{}
         |> Assistant.Schemas.User.changeset(user_attrs)
         |> Assistant.Repo.insert() do
      {:ok, user} ->
        link_settings_user(settings_user, user.id)

      {:error, changeset} ->
        case Assistant.Repo.get_by(Assistant.Schemas.User, external_id: user_attrs.external_id) do
          nil -> {:error, changeset}
          user -> link_settings_user(settings_user, user.id)
        end
    end
  end

  defp link_settings_user(settings_user, user_id) do
    settings_user
    |> Ecto.Changeset.change(user_id: user_id)
    |> Assistant.Repo.update()
    |> case do
      {:ok, _} -> {:ok, user_id}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp clear_oauth_session(conn) do
    conn
    |> delete_session(@state_session_key)
    |> delete_session(@pkce_verifier_session_key)
    |> delete_session(@popup_session_key)
    |> delete_session(@device_auth_id_session_key)
    |> delete_session(@device_user_code_session_key)
    |> delete_session(@device_poll_interval_session_key)
  end

  defp authorize_url,
    do: Application.get_env(:assistant, :openai_oauth_authorize_url, @default_authorize_url)

  defp token_url, do: Application.get_env(:assistant, :openai_oauth_token_url, @default_token_url)

  defp oauth_scope do
    Application.get_env(:assistant, :openai_oauth_scope, @default_scope)
  end

  defp callback_url do
    Application.get_env(
      :assistant,
      :openai_oauth_redirect_uri,
      url(~p"/auth/callback")
    )
  end

  defp maybe_add_codex_compat_params(params) do
    case Application.get_env(:assistant, :openai_oauth_codex_compat, true) do
      false ->
        params

      _ ->
        params
        |> Map.put("id_token_add_organizations", "true")
        |> Map.put("codex_cli_simplified_flow", "true")
        |> Map.put("originator", oauth_originator())
    end
  end

  defp oauth_originator do
    Application.get_env(:assistant, :openai_oauth_originator, @default_originator)
  end

  defp oauth_issuer do
    Application.get_env(:assistant, :openai_oauth_issuer, @default_issuer)
  end

  defp oauth_flow(params, popup?) do
    explicit_flow =
      case params do
        %{"flow" => value} when value in ["device", "browser"] -> value
        _ -> nil
      end

    configured_flow = Application.get_env(:assistant, :openai_oauth_flow, @default_oauth_flow)

    flow =
      cond do
        explicit_flow in ["device", "browser"] ->
          explicit_flow

        popup? ->
          # Old clients may still send only popup=1. Force device flow in popup mode
          # to avoid OpenAI browser-flow callback errors with the shared client ID.
          "device"

        configured_flow in ["device", "browser"] ->
          configured_flow

        true ->
          @default_oauth_flow
      end

    if flow == "browser", do: :browser, else: :device
  end

  defp popup_request_param?(%{"popup" => popup}) when popup in ["1", "true", "TRUE"], do: true
  defp popup_request_param?(_), do: false

  defp popup_request?(conn), do: get_session(conn, @popup_session_key) == true

  defp fetch_device_session(conn) do
    device_auth_id = get_session(conn, @device_auth_id_session_key)
    user_code = get_session(conn, @device_user_code_session_key)

    if is_binary(device_auth_id) and device_auth_id != "" and is_binary(user_code) and
         user_code != "" do
      {:ok, device_auth_id, user_code}
    else
      {:error, :missing_device_session}
    end
  end

  defp start_browser_oauth(conn, settings_user, popup?) do
    state = random_state()
    code_verifier = generate_code_verifier()
    code_challenge = generate_code_challenge(code_verifier)

    params =
      %{
        "response_type" => "code",
        "client_id" => fetch_client_id(),
        "redirect_uri" => callback_url(),
        "scope" => oauth_scope(),
        "state" => state,
        "code_challenge" => code_challenge,
        "code_challenge_method" => "S256"
      }
      |> maybe_add_codex_compat_params()
      |> URI.encode_query()

    Logger.info("OpenAI OAuth initiated (browser)", settings_user_id: settings_user.id)

    conn
    |> put_session(@state_session_key, state)
    |> put_session(@pkce_verifier_session_key, code_verifier)
    |> put_session(@popup_session_key, popup?)
    |> redirect(external: "#{authorize_url()}?#{params}")
  end

  defp start_device_oauth(conn, settings_user, popup?) do
    case request_device_code() do
      {:ok, %{"device_auth_id" => device_auth_id, "user_code" => user_code} = body} ->
        interval_ms =
          body
          |> Map.get("interval", "5")
          |> to_string()
          |> Integer.parse()
          |> case do
            {seconds, _} when seconds > 0 -> (seconds + 3) * 1000
            _ -> 8000
          end

        Logger.info("OpenAI OAuth initiated (device)", settings_user_id: settings_user.id)

        conn
        |> put_session(@popup_session_key, popup?)
        |> put_session(@device_auth_id_session_key, device_auth_id)
        |> put_session(@device_user_code_session_key, user_code)
        |> put_session(@device_poll_interval_session_key, interval_ms)
        |> device_oauth_html(user_code, interval_ms)

      {:error, reason} ->
        Logger.warning("OpenAI device code request failed", reason: inspect(reason))

        conn
        |> put_flash(:error, "Failed to start OpenAI device authorization. Please try again.")
        |> redirect(to: ~p"/settings")
    end
  end

  defp request_device_code do
    url = "#{oauth_issuer()}/api/accounts/deviceauth/usercode"

    case Req.post(url,
           json: %{"client_id" => fetch_client_id()},
           headers: [{"user-agent", oauth_user_agent()}]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:openai_device_code_failed, status, body}}

      {:error, reason} ->
        {:error, {:openai_device_code_http_error, reason}}
    end
  end

  defp poll_device_authorization(device_auth_id, user_code) do
    url = "#{oauth_issuer()}/api/accounts/deviceauth/token"

    case Req.post(url,
           json: %{"device_auth_id" => device_auth_id, "user_code" => user_code},
           headers: [{"user-agent", oauth_user_agent()}]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        authorization_code = Map.get(body, "authorization_code")
        code_verifier = Map.get(body, "code_verifier")

        if is_binary(authorization_code) and authorization_code != "" and is_binary(code_verifier) and
             code_verifier != "" do
          {:ok, {:approved, authorization_code, code_verifier}}
        else
          {:error, :invalid_device_token_payload}
        end

      {:ok, %Req.Response{status: status}} when status in [403, 404] ->
        {:ok, :pending}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:openai_device_poll_failed, status, body}}

      {:error, reason} ->
        {:error, {:openai_device_poll_http_error, reason}}
    end
  end

  defp finish_callback(conn, false, level, message, redirect_path) do
    conn
    |> put_flash(level, message)
    |> redirect(to: redirect_path)
  end

  defp finish_callback(conn, true, level, message, _redirect_path) do
    conn
    |> put_flash(level, message)
    |> popup_close_html(message, level == :info)
  end

  defp popup_close_html(conn, message, success?) do
    status_icon = if success?, do: "&#10004;&#65039;", else: "&#9888;&#65039;"
    title = if success?, do: "OpenAI Connected", else: "OpenAI Connection Failed"

    html(
      conn,
      """
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>#{title}</title>
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                 display: flex; justify-content: center; align-items: center; min-height: 100vh;
                 margin: 0; background: #f8f9fa; color: #333; }
          .card { background: white; border-radius: 12px; padding: 2rem; max-width: 420px;
                  text-align: center; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
          .icon { font-size: 3rem; margin-bottom: 1rem; }
          h1 { font-size: 1.2rem; margin: 0 0 0.5rem; }
          p { color: #666; margin: 0; font-size: 0.95rem; }
        </style>
      </head>
      <body>
        <div class="card">
          <div class="icon">#{status_icon}</div>
          <h1>#{title}</h1>
          <p>#{message}</p>
          <p style="margin-top: 1rem;">This window will close automatically.</p>
        </div>
        <script>
          setTimeout(function() { window.close(); }, 1000);
        </script>
      </body>
      </html>
      """
    )
  end

  defp device_oauth_html(conn, user_code, interval_ms) do
    encoded_user_code = escape_html(user_code)
    poll_url = ~p"/settings_users/auth/openai/device/poll"
    device_url = "#{oauth_issuer()}/codex/device"

    html(
      conn,
      """
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>OpenAI Device Login</title>
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                 display: flex; justify-content: center; align-items: center; min-height: 100vh;
                 margin: 0; background: #f8f9fa; color: #333; }
          .card { background: white; border-radius: 12px; padding: 2rem; max-width: 460px;
                  text-align: center; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
          .code { font-size: 1.8rem; letter-spacing: 0.08em; font-weight: 700;
                  padding: 0.75rem 1rem; border: 1px solid #d0d7de; border-radius: 8px;
                  background: #f6f8fa; margin: 0.75rem 0 1rem; }
          .btn { display: inline-block; padding: 0.65rem 1rem; border-radius: 8px;
                 background: #111827; color: #fff; text-decoration: none; font-weight: 600; }
          .muted { color: #6b7280; font-size: 0.9rem; margin-top: 0.75rem; }
        </style>
      </head>
      <body>
        <div class="card">
          <h1>Connect OpenAI</h1>
          <p>Use this code at OpenAI device login:</p>
          <div class="code">#{encoded_user_code}</div>
          <a class="btn" href="#{device_url}" target="_blank" rel="noopener noreferrer">Open OpenAI Device Login</a>
          <p class="muted" id="status">Waiting for authorization...</p>
        </div>
        <script>
          const statusEl = document.getElementById("status");
          async function poll() {
            try {
              const res = await fetch("#{poll_url}", { credentials: "same-origin" });
              const data = await res.json();
              if (data.status === "connected") {
                statusEl.textContent = "Connected. Closing...";
                setTimeout(function() { window.close(); }, 700);
                return;
              }
              if (data.status === "error") {
                statusEl.textContent = data.message || "Connection failed.";
                return;
              }
            } catch (_err) {
              statusEl.textContent = "Network error while checking authorization.";
              return;
            }
            setTimeout(poll, #{interval_ms});
          }
          setTimeout(poll, #{interval_ms});
        </script>
      </body>
      </html>
      """
    )
  end

  defp oauth_attrs_from_tokens(tokens, access_token) do
    expires_in =
      case Map.get(tokens, "expires_in") do
        value when is_integer(value) and value > 0 -> value
        _ -> nil
      end

    %{
      access_token: access_token,
      refresh_token: Map.get(tokens, "refresh_token"),
      account_id: extract_account_id(tokens),
      expires_at: expires_at_from_seconds(expires_in)
    }
  end

  defp expires_at_from_seconds(nil), do: nil

  defp expires_at_from_seconds(seconds) when is_integer(seconds) and seconds > 0 do
    DateTime.utc_now()
    |> DateTime.add(seconds, :second)
    |> DateTime.truncate(:second)
  end

  defp extract_account_id(tokens) when is_map(tokens) do
    tokens
    |> extract_claims_from_tokens()
    |> Enum.find_value(&extract_account_id_from_claims/1)
  end

  defp extract_account_id(_), do: nil

  defp extract_claims_from_tokens(tokens) do
    ["id_token", "access_token"]
    |> Enum.map(&Map.get(tokens, &1))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&decode_jwt_claims/1)
    |> Enum.filter(&is_map/1)
  end

  defp extract_account_id_from_claims(claims) do
    claims["chatgpt_account_id"] ||
      get_in(claims, ["https://api.openai.com/auth", "chatgpt_account_id"]) ||
      get_in(claims, ["organizations", Access.at(0), "id"])
  end

  defp decode_jwt_claims(token) when is_binary(token) do
    with [_, payload, _] <- String.split(token, ".", parts: 3),
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(decoded),
         true <- is_map(claims) do
      claims
    else
      _ -> nil
    end
  end

  defp oauth_user_agent do
    Application.get_env(:assistant, :openai_oauth_user_agent, "synaptic-assistant/1.0")
  end

  defp escape_html(value) when is_binary(value) do
    value
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp random_state do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  defp generate_code_verifier do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  defp generate_code_challenge(verifier) do
    :crypto.hash(:sha256, verifier)
    |> Base.url_encode64(padding: false)
  end
end

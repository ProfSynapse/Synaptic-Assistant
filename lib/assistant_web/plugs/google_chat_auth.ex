# lib/assistant_web/plugs/google_chat_auth.ex — JWT verification for Google Chat webhooks.
#
# Phoenix Plug that verifies the Bearer JWT sent by Google Chat on every
# webhook request. Uses JOSE to verify
# RS256 signatures against Google's public X.509 certificates.
#
# Certificates are cached in an ETS table with a 1-hour TTL, keyed by issuer
# to support multiple Google service accounts (Chat API vs G Suite Add-ons).
#
# Related files:
#   - lib/assistant_web/controllers/google_chat_controller.ex (consumer)
#   - lib/assistant_web/router.ex (where this plug is applied)
#   - lib/assistant/integrations/google/auth.ex (service account auth — different concern)

defmodule AssistantWeb.Plugs.GoogleChatAuth do
  @moduledoc """
  Phoenix Plug that verifies Google Chat JWT Bearer tokens.

  Every incoming Google Chat webhook request includes an `Authorization: Bearer <JWT>`
  header signed by Google. This plug:

    1. Extracts the Bearer token from the Authorization header
    2. Peeks at the JWT header (`kid`) and payload (`iss`) without verifying
    3. Validates the `iss` claim is an allowed Google service account
    4. Fetches (and caches per-issuer) Google's public X.509 certificates
    5. Verifies the RS256 signature against the matching public key
    6. Validates `iss`, `aud`, and `exp` claims
    7. On success, assigns `:google_chat_claims` to the conn
    8. On failure, returns 401 with no error details

  ## Supported Issuers

  Google Chat may sign JWTs with different service accounts depending on configuration:

    * `chat@system.gserviceaccount.com` — standard Chat API service account
    * `*@gcp-sa-gsuiteaddons.iam.gserviceaccount.com` — G Suite Add-ons HTTP endpoint mode

  Certificates are fetched dynamically from Google's public endpoint based on the
  JWT's `iss` claim, with validation that the issuer is a legitimate Google service account.

  ## Configuration

  Requires `:google_cloud_project_number` via IntegrationSettings (DB or env var fallback):

      # Via env var:
      GOOGLE_CLOUD_PROJECT_NUMBER=1234567890
      # Or via admin UI integration settings
  """

  import Plug.Conn

  alias Assistant.IntegrationSettings

  require Logger

  @behaviour Plug

  @google_certs_base_url "https://www.googleapis.com/service_accounts/v1/metadata/x509/"
  @cache_table :google_chat_certs_cache
  @cache_ttl_ms :timer.hours(1)
  @clock_skew_seconds 30

  # Allowed issuer patterns for Google Chat webhook JWTs.
  # The Chat API uses its own service account; G Suite Add-ons uses a project-
  # scoped service account with a different domain suffix.
  @allowed_issuers_exact MapSet.new([
                           "chat@system.gserviceaccount.com"
                         ])
  @allowed_issuer_suffixes [
    "@gcp-sa-gsuiteaddons.iam.gserviceaccount.com"
  ]

  # --- Plug Callbacks ---

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, token} <- extract_bearer_token(conn),
         {:ok, claims} <- verify_jwt(token) do
      assign(conn, :google_chat_claims, claims)
    else
      {:error, reason} ->
        Logger.warning("Google Chat JWT verification failed: #{inspect(reason)}",
          request_id: conn.assigns[:request_id]
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{"error" => "Unauthorized"}))
        |> halt()
    end
  end

  # --- Token Extraction ---

  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> {:error, :missing_bearer_token}
    end
  end

  # --- JWT Verification ---

  defp verify_jwt(token) do
    project_number = IntegrationSettings.get(:google_cloud_project_number)

    if is_nil(project_number) do
      Logger.error("google_cloud_project_number not configured")
      {:error, :missing_project_number}
    else
      do_verify(token, project_number)
    end
  end

  defp do_verify(token, project_number) do
    with {:ok, kid} <- extract_kid(token),
         {:ok, issuer} <- extract_issuer(token),
         :ok <- validate_issuer(issuer),
         {:ok, jwk} <- get_public_key(kid, issuer),
         {:ok, claims} <- verify_signature(jwk, token),
         :ok <- validate_claims(claims, project_number) do
      {:ok, claims}
    end
  end

  # Extract the `kid` from the JWT header without verifying (we need it to pick the key).
  defp extract_kid(token) do
    case JOSE.JWT.peek_protected(token) do
      %JOSE.JWS{fields: %{"kid" => kid}} when is_binary(kid) ->
        {:ok, kid}

      _ ->
        {:error, :missing_kid}
    end
  rescue
    _ -> {:error, :invalid_token_header}
  end

  # Extract the `iss` claim from the JWT payload without verifying signature.
  # We need the issuer to determine which cert endpoint to fetch from.
  @doc false
  def extract_issuer(token) do
    case JOSE.JWT.peek_payload(token) do
      %JOSE.JWT{fields: %{"iss" => iss}} when is_binary(iss) and iss != "" ->
        {:ok, iss}

      _ ->
        {:error, :missing_issuer}
    end
  rescue
    _ -> {:error, :invalid_token_payload}
  end

  # Validate the issuer is an allowed Google service account before fetching certs.
  # Security: prevents cert fetches from arbitrary URLs controlled by an attacker.
  @doc false
  def validate_issuer(issuer) do
    if allowed_issuer?(issuer) do
      :ok
    else
      Logger.warning("Google Chat JWT rejected: disallowed issuer #{inspect(issuer)}")
      {:error, :disallowed_issuer}
    end
  end

  @doc false
  def allowed_issuer?(issuer) when is_binary(issuer) do
    MapSet.member?(@allowed_issuers_exact, issuer) or
      Enum.any?(@allowed_issuer_suffixes, &String.ends_with?(issuer, &1))
  end

  def allowed_issuer?(_), do: false

  # Build the Google public certs URL for a given issuer.
  @doc false
  def certs_url_for_issuer(issuer) do
    @google_certs_base_url <> URI.encode_www_form(issuer)
  end

  # Look up the cached public key for the given kid and issuer, fetching certs if needed.
  defp get_public_key(kid, issuer) do
    case get_cached_certs(issuer) do
      {:ok, certs} ->
        case Map.get(certs, kid) do
          nil -> {:error, :unknown_kid}
          pem -> pem_to_jwk(pem)
        end

      {:error, _reason} = error ->
        error
    end
  end

  # Convert a PEM-encoded X.509 certificate to a JOSE JWK public key.
  defp pem_to_jwk(pem) do
    try do
      # Decode the PEM certificate and extract the public key
      [{:Certificate, der, _}] = :public_key.pem_decode(pem)
      cert = :public_key.pkix_decode_cert(der, :otp)
      public_key = elem(elem(cert, 1), 7)
      # public_key is an {:OTPSubjectPublicKeyInfo, ...} record — extract the RSA key
      rsa_key = elem(public_key, 1)
      {:ok, JOSE.JWK.from_key(rsa_key)}
    rescue
      error ->
        Logger.warning("Failed to parse X.509 certificate: #{inspect(error)}")
        {:error, :invalid_certificate}
    end
  end

  # Verify the JWT signature using the JWK and RS256 algorithm.
  defp verify_signature(jwk, token) do
    case JOSE.JWT.verify_strict(jwk, ["RS256"], token) do
      {true, %JOSE.JWT{fields: claims}, _jws} ->
        {:ok, claims}

      {false, _jwt, _jws} ->
        {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :verification_error}
  end

  # Validate iss, aud, and exp claims.
  # The issuer has already been validated against the allowlist before cert fetch,
  # but we re-check here to ensure the verified payload matches.
  defp validate_claims(claims, project_number) do
    now = System.system_time(:second)

    cond do
      not allowed_issuer?(claims["iss"]) ->
        {:error, :invalid_issuer}

      claims["aud"] != project_number ->
        {:error, :invalid_audience}

      not is_integer(claims["exp"]) or claims["exp"] + @clock_skew_seconds <= now ->
        {:error, :token_expired}

      true ->
        :ok
    end
  end

  # --- Certificate Caching (per-issuer) ---

  defp get_cached_certs(issuer) do
    ensure_ets_table()
    cache_key = {:certs, issuer}

    case :ets.lookup(@cache_table, cache_key) do
      [{^cache_key, certs, cached_at}] ->
        if System.monotonic_time(:millisecond) - cached_at < @cache_ttl_ms do
          {:ok, certs}
        else
          fetch_and_cache_certs(issuer)
        end

      [] ->
        fetch_and_cache_certs(issuer)
    end
  end

  defp fetch_and_cache_certs(issuer) do
    url = certs_url_for_issuer(issuer)
    Logger.info("Fetching Google Chat public certificates from #{url}")

    case Req.get(url) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        now = System.monotonic_time(:millisecond)
        :ets.insert(@cache_table, {{:certs, issuer}, body, now})
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        Logger.error("Failed to fetch Google certs for #{issuer}: HTTP #{status}")
        {:error, :cert_fetch_failed}

      {:error, reason} ->
        Logger.error("Failed to fetch Google certs for #{issuer}: #{inspect(reason)}")
        {:error, :cert_fetch_failed}
    end
  end

  defp ensure_ets_table do
    case :ets.whereis(@cache_table) do
      :undefined ->
        :ets.new(@cache_table, [:set, :protected, :named_table])

      _ref ->
        :ok
    end
  rescue
    ArgumentError ->
      # Table may have been created by another process between check and create
      :ok
  end
end

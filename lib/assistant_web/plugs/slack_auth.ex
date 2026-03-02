# lib/assistant_web/plugs/slack_auth.ex — HMAC-SHA256 signing verification for Slack webhooks.
#
# Phoenix Plug that verifies the signature sent by Slack on every webhook
# request. Uses HMAC-SHA256 with the app's signing secret to verify that
# requests originate from Slack. Includes replay protection via timestamp
# validation.
#
# Related files:
#   - lib/assistant_web/plugs/cache_raw_body.ex (caches raw body for HMAC computation)
#   - lib/assistant_web/controllers/slack_controller.ex (consumer)
#   - lib/assistant_web/router.ex (where this plug is applied)

defmodule AssistantWeb.Plugs.SlackAuth do
  @moduledoc """
  Phoenix Plug that verifies Slack request signatures.

  Slack sends three headers on every webhook request:

    * `X-Slack-Signature` — HMAC-SHA256 signature: `v0={hex_digest}`
    * `X-Slack-Request-Timestamp` — Unix timestamp of the request
    * `X-Slack-Retry-Num` — (optional) Retry count for failed deliveries

  ## Verification Algorithm

    1. Extract timestamp from `X-Slack-Request-Timestamp`
    2. Reject if timestamp is older than 5 minutes (replay protection)
    3. Construct basestring: `v0:{timestamp}:{raw_request_body}`
    4. Compute HMAC-SHA256 of basestring using the signing secret
    5. Compare `v0={hex_digest}` against `X-Slack-Signature` (constant-time)

  ## Configuration

  Requires `:slack_signing_secret` in the `:assistant` app env:

      config :assistant, slack_signing_secret: "your-signing-secret"

  Also requires `CacheRawBody` body reader configured in `endpoint.ex`.
  """

  import Plug.Conn

  alias Assistant.IntegrationSettings

  require Logger

  @behaviour Plug

  @max_timestamp_age_seconds 300

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    signing_secret = IntegrationSettings.get(:slack_signing_secret)

    with {:ok, signature} <- get_header(conn, "x-slack-signature"),
         {:ok, timestamp} <- get_header(conn, "x-slack-request-timestamp"),
         :ok <- validate_timestamp(timestamp),
         {:ok, raw_body} <- get_raw_body(conn),
         :ok <- verify_signature(signature, timestamp, raw_body, signing_secret) do
      assign(conn, :slack_verified, true)
    else
      {:error, reason} ->
        Logger.warning("Slack webhook auth failed",
          reason: reason,
          remote_ip: to_string(:inet_parse.ntoa(conn.remote_ip))
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{"error" => "Unauthorized"}))
        |> halt()
    end
  end

  defp get_header(conn, header) do
    case get_req_header(conn, header) do
      [value] when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :"missing_#{String.replace(header, "-", "_")}"}
    end
  end

  defp validate_timestamp(timestamp_str) do
    case Integer.parse(timestamp_str) do
      {ts, ""} ->
        now = System.system_time(:second)

        if abs(now - ts) <= @max_timestamp_age_seconds do
          :ok
        else
          {:error, :timestamp_too_old}
        end

      _ ->
        {:error, :invalid_timestamp}
    end
  end

  defp get_raw_body(conn) do
    case conn.private[:raw_body] do
      nil -> {:error, :raw_body_not_cached}
      body when is_binary(body) -> {:ok, body}
    end
  end

  defp verify_signature(_received, _timestamp, _raw_body, nil) do
    Logger.error("slack_signing_secret not configured — rejecting all requests")
    {:error, :secret_not_configured}
  end

  defp verify_signature(received_signature, timestamp, raw_body, signing_secret) do
    basestring = "v0:#{timestamp}:#{raw_body}"

    computed_hmac =
      :crypto.mac(:hmac, :sha256, signing_secret, basestring)
      |> Base.encode16(case: :lower)

    expected_signature = "v0=#{computed_hmac}"

    if Plug.Crypto.secure_compare(received_signature, expected_signature) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end
end

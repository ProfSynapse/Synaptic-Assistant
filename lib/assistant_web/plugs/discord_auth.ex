# lib/assistant_web/plugs/discord_auth.ex — Ed25519 signature verification for Discord webhooks.
#
# Phoenix Plug that verifies the Ed25519 signature sent by Discord on every
# interaction webhook request. Discord signs the request body with the
# application's public key using Ed25519.
#
# Related files:
#   - lib/assistant_web/plugs/cache_raw_body.ex (caches raw body for signature computation)
#   - lib/assistant_web/controllers/discord_controller.ex (consumer)
#   - lib/assistant_web/router.ex (where this plug is applied)

defmodule AssistantWeb.Plugs.DiscordAuth do
  @moduledoc """
  Phoenix Plug that verifies Discord interaction webhook signatures.

  Discord sends two headers on every interaction webhook request:

    * `X-Signature-Ed25519` — Hex-encoded Ed25519 signature
    * `X-Signature-Timestamp` — Timestamp string used in signature

  ## Verification Algorithm

    1. Extract signature from `X-Signature-Ed25519` (hex-encoded)
    2. Extract timestamp from `X-Signature-Timestamp`
    3. Construct message: `{timestamp}{raw_request_body}`
    4. Verify Ed25519 signature against message using the public key
    5. Signature and public key are hex-encoded — decode to binary before verification

  ## Configuration

  Requires `:discord_public_key` in the `:assistant` app env:

      config :assistant, discord_public_key: "your-hex-encoded-public-key"

  Also requires `CacheRawBody` body reader configured in `endpoint.ex`.
  If no public key is configured, all requests are rejected (fail-closed).
  """

  import Plug.Conn

  alias Assistant.IntegrationSettings

  require Logger

  @behaviour Plug

  @max_timestamp_age 300

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    public_key_hex = IntegrationSettings.get(:discord_public_key)

    with {:ok, signature_hex} <- get_header(conn, "x-signature-ed25519"),
         {:ok, timestamp} <- get_header(conn, "x-signature-timestamp"),
         :ok <- validate_timestamp(timestamp),
         {:ok, raw_body} <- get_raw_body(conn),
         :ok <- verify_signature(signature_hex, timestamp, raw_body, public_key_hex) do
      assign(conn, :discord_verified, true)
    else
      {:error, reason} ->
        Logger.warning("Discord webhook auth failed",
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

        if abs(now - ts) <= @max_timestamp_age do
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

  defp verify_signature(_signature_hex, _timestamp, _raw_body, nil) do
    Logger.error("discord_public_key not configured — rejecting all requests")
    {:error, :public_key_not_configured}
  end

  defp verify_signature(signature_hex, timestamp, raw_body, public_key_hex) do
    with {:ok, signature} <- hex_decode(signature_hex, :invalid_signature_format),
         {:ok, public_key} <- hex_decode(public_key_hex, :invalid_public_key_format) do
      message = timestamp <> raw_body

      if :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519]) do
        :ok
      else
        {:error, :invalid_signature}
      end
    end
  end

  defp hex_decode(hex_string, error_atom) do
    case Base.decode16(hex_string, case: :mixed) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, error_atom}
    end
  end
end

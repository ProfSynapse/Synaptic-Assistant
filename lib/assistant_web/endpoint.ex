# lib/assistant_web/endpoint.ex — Phoenix HTTP endpoint.
#
# Entry point for all HTTP requests. Webhooks-only configuration.
# No static file serving, no session, no CSRF (API/webhook-only).

defmodule AssistantWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :assistant

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Phoenix.json_library()

  plug AssistantWeb.Router
end

# lib/assistant_web/controllers/health_controller.ex — Health check endpoint.
#
# Returns system health status. Used by Railway health checks and monitoring.
# GET /health returns 200 with JSON body.

defmodule AssistantWeb.HealthController do
  use AssistantWeb, :controller

  @doc """
  Returns a simple health check response.

  Used by Railway for liveness/readiness probes.
  """
  def index(conn, _params) do
    json(conn, %{status: "ok", timestamp: DateTime.utc_now()})
  end
end

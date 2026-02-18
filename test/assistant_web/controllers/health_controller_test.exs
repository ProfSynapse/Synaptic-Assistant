# test/assistant_web/controllers/health_controller_test.exs — Health endpoint tests.
#
# Verifies the /health endpoint returns 200 with expected JSON body.

defmodule AssistantWeb.HealthControllerTest do
  use AssistantWeb.ConnCase, async: true

  describe "GET /health" do
    test "returns 200 with status ok", %{conn: conn} do
      conn = get(conn, "/health")

      assert json_response(conn, 200)["status"] == "ok"
    end

    test "includes a timestamp", %{conn: conn} do
      conn = get(conn, "/health")

      response = json_response(conn, 200)
      assert Map.has_key?(response, "timestamp")
    end
  end
end

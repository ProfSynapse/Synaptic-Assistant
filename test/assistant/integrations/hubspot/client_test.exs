# test/assistant/integrations/hubspot/client_test.exs
#
# Tests for the HubSpot CRM v3 API HTTP client. Uses Bypass to mock
# HTTP endpoints. Covers health_check, CRUD, search, and list operations
# for contacts, companies, and deals, plus error handling for common
# HTTP status codes and network failures.
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (module under test)
#   - test/assistant/integration_settings/connection_validator_test.exs (pattern reference)

defmodule Assistant.Integrations.HubSpot.ClientTest do
  use ExUnit.Case, async: false

  alias Assistant.Integrations.HubSpot.Client

  @api_key "pat-test-key"

  # ---------------------------------------------------------------
  # Setup — Bypass + base_url override
  # ---------------------------------------------------------------

  setup do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"

    prev_base_url = Application.get_env(:assistant, :hubspot_api_base_url)
    Application.put_env(:assistant, :hubspot_api_base_url, base_url)

    on_exit(fn ->
      if prev_base_url,
        do: Application.put_env(:assistant, :hubspot_api_base_url, prev_base_url),
        else: Application.delete_env(:assistant, :hubspot_api_base_url)
    end)

    %{bypass: bypass}
  end

  # ---------------------------------------------------------------
  # Health Check
  # ---------------------------------------------------------------

  describe "health_check/1" do
    test "returns {:ok, :healthy} on 200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/crm/v3/objects/contacts", fn conn ->
        assert_auth_header(conn, @api_key)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"results" => []}))
      end)

      assert {:ok, :healthy} = Client.health_check(@api_key)
    end

    test "returns {:error, {:api_error, 401, _}} on unauthorized", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/crm/v3/objects/contacts", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(401, Jason.encode!(%{"message" => "Unauthorized"}))
      end)

      assert {:error, {:api_error, 401, "Unauthorized"}} = Client.health_check(@api_key)
    end

    test "returns {:error, {:request_failed, _}} on network failure", %{bypass: bypass} do
      Bypass.down(bypass)

      assert {:error, {:request_failed, _reason}} = Client.health_check(@api_key)
    end
  end

  # ---------------------------------------------------------------
  # Contacts — CRUD + search + list
  # ---------------------------------------------------------------

  describe "create_contact/2" do
    test "returns normalized object on 201", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/crm/v3/objects/contacts", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["properties"]["email"] == "j@example.com"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          201,
          Jason.encode!(%{
            "id" => "101",
            "properties" => %{"email" => "j@example.com", "firstname" => "Jane"},
            "createdAt" => "2026-01-01T00:00:00Z",
            "updatedAt" => "2026-01-01T00:00:00Z"
          })
        )
      end)

      assert {:ok, contact} = Client.create_contact(@api_key, %{"email" => "j@example.com"})
      assert contact.id == "101"
      assert contact.properties["email"] == "j@example.com"
      assert contact.created_at == "2026-01-01T00:00:00Z"
    end

    test "returns api_error on 409 conflict", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/crm/v3/objects/contacts", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(409, Jason.encode!(%{"message" => "Contact already exists"}))
      end)

      assert {:error, {:api_error, 409, "Contact already exists"}} =
               Client.create_contact(@api_key, %{"email" => "j@example.com"})
    end
  end

  describe "get_contact/2" do
    test "returns normalized object on 200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/crm/v3/objects/contacts/101", fn conn ->
        assert_auth_header(conn, @api_key)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "101",
            "properties" => %{"email" => "j@example.com"},
            "createdAt" => "2026-01-01T00:00:00Z",
            "updatedAt" => "2026-01-01T00:00:00Z"
          })
        )
      end)

      assert {:ok, contact} = Client.get_contact(@api_key, "101")
      assert contact.id == "101"
    end

    test "returns 404 error for missing contact", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/crm/v3/objects/contacts/999", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"message" => "Not found"}))
      end)

      assert {:error, {:api_error, 404, "Not found"}} = Client.get_contact(@api_key, "999")
    end
  end

  describe "update_contact/3" do
    test "returns updated object on 200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PATCH", "/crm/v3/objects/contacts/101", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["properties"]["phone"] == "555-1234"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "101",
            "properties" => %{"email" => "j@example.com", "phone" => "555-1234"},
            "createdAt" => "2026-01-01T00:00:00Z",
            "updatedAt" => "2026-01-02T00:00:00Z"
          })
        )
      end)

      assert {:ok, contact} =
               Client.update_contact(@api_key, "101", %{"phone" => "555-1234"})

      assert contact.properties["phone"] == "555-1234"
    end
  end

  describe "delete_contact/2" do
    test "returns :ok on 204", %{bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/crm/v3/objects/contacts/101", fn conn ->
        assert_auth_header(conn, @api_key)
        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = Client.delete_contact(@api_key, "101")
    end

    test "returns 404 for missing contact", %{bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/crm/v3/objects/contacts/999", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"message" => "Not found"}))
      end)

      assert {:error, {:api_error, 404, "Not found"}} = Client.delete_contact(@api_key, "999")
    end
  end

  describe "search_contacts/5" do
    test "returns list of normalized objects on 200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/crm/v3/objects/contacts/search", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["limit"] == 5
        [group] = decoded["filterGroups"]
        [filter] = group["filters"]
        assert filter["propertyName"] == "email"
        assert filter["operator"] == "EQ"
        assert filter["value"] == "j@example.com"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "results" => [
              %{
                "id" => "101",
                "properties" => %{"email" => "j@example.com"},
                "createdAt" => "2026-01-01T00:00:00Z",
                "updatedAt" => "2026-01-01T00:00:00Z"
              }
            ]
          })
        )
      end)

      assert {:ok, [contact]} =
               Client.search_contacts(@api_key, "email", "EQ", "j@example.com", 5)

      assert contact.id == "101"
    end

    test "returns empty list when no results", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/crm/v3/objects/contacts/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"results" => []}))
      end)

      assert {:ok, []} = Client.search_contacts(@api_key, "email", "EQ", "nobody@x.com", 10)
    end
  end

  describe "list_recent_contacts/2" do
    test "returns list of normalized objects", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/crm/v3/objects/contacts", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["limit"] == "10"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "results" => [
              %{
                "id" => "101",
                "properties" => %{"email" => "j@example.com"},
                "createdAt" => "2026-01-01T00:00:00Z",
                "updatedAt" => "2026-01-01T00:00:00Z"
              },
              %{
                "id" => "102",
                "properties" => %{"email" => "k@example.com"},
                "createdAt" => "2026-01-02T00:00:00Z",
                "updatedAt" => "2026-01-02T00:00:00Z"
              }
            ]
          })
        )
      end)

      assert {:ok, contacts} = Client.list_recent_contacts(@api_key, 10)
      assert length(contacts) == 2
    end
  end

  # ---------------------------------------------------------------
  # Companies — representative tests (same generic CRM operations)
  # ---------------------------------------------------------------

  describe "create_company/2" do
    test "returns normalized object on 201", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/crm/v3/objects/companies", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          201,
          Jason.encode!(%{
            "id" => "201",
            "properties" => %{"name" => "Acme Corp"},
            "createdAt" => "2026-01-01T00:00:00Z",
            "updatedAt" => "2026-01-01T00:00:00Z"
          })
        )
      end)

      assert {:ok, company} = Client.create_company(@api_key, %{"name" => "Acme Corp"})
      assert company.id == "201"
      assert company.properties["name"] == "Acme Corp"
    end
  end

  describe "search_companies/5" do
    test "returns list of normalized objects", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/crm/v3/objects/companies/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "results" => [
              %{
                "id" => "201",
                "properties" => %{"name" => "Acme Corp"},
                "createdAt" => "2026-01-01T00:00:00Z",
                "updatedAt" => "2026-01-01T00:00:00Z"
              }
            ]
          })
        )
      end)

      assert {:ok, [company]} =
               Client.search_companies(@api_key, "name", "CONTAINS_TOKEN", "Acme", 10)

      assert company.id == "201"
    end
  end

  # ---------------------------------------------------------------
  # Deals — representative tests
  # ---------------------------------------------------------------

  describe "create_deal/2" do
    test "returns normalized object on 201", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/crm/v3/objects/deals", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          201,
          Jason.encode!(%{
            "id" => "301",
            "properties" => %{"dealname" => "Big Deal", "amount" => "50000"},
            "createdAt" => "2026-01-01T00:00:00Z",
            "updatedAt" => "2026-01-01T00:00:00Z"
          })
        )
      end)

      assert {:ok, deal} = Client.create_deal(@api_key, %{"dealname" => "Big Deal"})
      assert deal.id == "301"
    end
  end

  describe "delete_deal/2" do
    test "returns :ok on 204", %{bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/crm/v3/objects/deals/301", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = Client.delete_deal(@api_key, "301")
    end
  end

  # ---------------------------------------------------------------
  # Common error handling (applies to all object types)
  # ---------------------------------------------------------------

  describe "common error handling" do
    test "returns api_error on 401 unauthorized", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/crm/v3/objects/contacts/101", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(401, Jason.encode!(%{"message" => "Invalid API key"}))
      end)

      assert {:error, {:api_error, 401, "Invalid API key"}} =
               Client.get_contact(@api_key, "101")
    end

    test "returns api_error on 429 rate limit", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/crm/v3/objects/companies/201", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, Jason.encode!(%{"message" => "Rate limit exceeded"}))
      end)

      assert {:error, {:api_error, 429, "Rate limit exceeded"}} =
               Client.get_company(@api_key, "201")
    end

    test "returns request_failed on network error", %{bypass: bypass} do
      Bypass.down(bypass)

      assert {:error, {:request_failed, _}} = Client.get_deal(@api_key, "301")
    end

    test "extracts error message from body without message key", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/crm/v3/objects/contacts/101", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"status" => "error", "category" => "INTERNAL"}))
      end)

      {:error, {:api_error, 500, message}} = Client.get_contact(@api_key, "101")
      # Falls back to inspect(body) when no "message" key
      assert is_binary(message)
      assert message =~ "INTERNAL"
    end
  end

  # ---------------------------------------------------------------
  # normalize_object/1 edge cases
  # ---------------------------------------------------------------

  describe "normalize_object edge cases" do
    test "handles missing properties in response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/crm/v3/objects/contacts/101", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"id" => "101"}))
      end)

      assert {:ok, contact} = Client.get_contact(@api_key, "101")
      assert contact.id == "101"
      assert contact.properties == %{}
      assert contact.created_at == nil
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp assert_auth_header(conn, api_key) do
    {_key, auth_value} =
      Enum.find(conn.req_headers, fn {k, _v} -> k == "authorization" end)

    assert auth_value == "Bearer #{api_key}"
    conn
  end
end

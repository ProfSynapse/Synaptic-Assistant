# test/assistant/skills/hubspot/helpers_test.exs
#
# Tests for HubSpot-domain shared helpers. All functions are pure (except
# resolve_api_key which reads Application env), so tests can run async.
#
# Related files:
#   - lib/assistant/skills/hubspot/helpers.ex (module under test)
#   - lib/assistant/skills/helpers.ex (cross-domain parse_limit)

defmodule Assistant.Skills.HubSpot.HelpersTest do
  use ExUnit.Case, async: true

  alias Assistant.Skills.HubSpot.Helpers
  alias Assistant.Skills.Result

  # ---------------------------------------------------------------
  # parse_limit/1
  # ---------------------------------------------------------------

  describe "parse_limit/1" do
    test "returns default 10 for nil" do
      assert Helpers.parse_limit(nil) == 10
    end

    test "parses valid integer string" do
      assert Helpers.parse_limit("25") == 25
    end

    test "clamps to minimum 1" do
      assert Helpers.parse_limit("0") == 1
      assert Helpers.parse_limit("-5") == 1
    end

    test "clamps to maximum 50" do
      assert Helpers.parse_limit("100") == 50
      assert Helpers.parse_limit("51") == 50
    end

    test "returns default for non-numeric string" do
      assert Helpers.parse_limit("abc") == 10
    end

    test "accepts integer directly" do
      assert Helpers.parse_limit(30) == 30
    end

    test "boundary values" do
      assert Helpers.parse_limit("1") == 1
      assert Helpers.parse_limit("50") == 50
    end
  end

  # ---------------------------------------------------------------
  # maybe_put/3
  # ---------------------------------------------------------------

  describe "maybe_put/3" do
    test "puts value when present" do
      assert Helpers.maybe_put(%{}, "email", "j@example.com") == %{"email" => "j@example.com"}
    end

    test "skips nil values" do
      assert Helpers.maybe_put(%{"a" => 1}, "email", nil) == %{"a" => 1}
    end

    test "skips empty string values" do
      assert Helpers.maybe_put(%{"a" => 1}, "email", "") == %{"a" => 1}
    end

    test "preserves existing keys" do
      map = %{"email" => "old@example.com"}
      assert Helpers.maybe_put(map, "phone", "555") == %{"email" => "old@example.com", "phone" => "555"}
    end
  end

  # ---------------------------------------------------------------
  # format_object/2
  # ---------------------------------------------------------------

  describe "format_object/2" do
    @fields [{"Email", "email"}, {"First Name", "firstname"}, {"Phone", "phone"}]

    test "formats object with atom-keyed properties" do
      object = %{id: "101", properties: %{"email" => "j@example.com", "firstname" => "Jane"}}
      result = Helpers.format_object(object, @fields)

      assert result =~ "ID: 101"
      assert result =~ "Email: j@example.com"
      assert result =~ "First Name: Jane"
    end

    test "omits nil property values" do
      object = %{id: "101", properties: %{"email" => "j@example.com"}}
      result = Helpers.format_object(object, @fields)

      assert result =~ "Email: j@example.com"
      refute result =~ "First Name:"
      refute result =~ "Phone:"
    end

    test "handles string-keyed object (API response format)" do
      object = %{"id" => "101", "properties" => %{"email" => "j@example.com"}}
      result = Helpers.format_object(object, @fields)

      assert result =~ "ID: 101"
      assert result =~ "Email: j@example.com"
    end

    test "always includes ID as first line" do
      object = %{id: "101", properties: %{}}
      result = Helpers.format_object(object, @fields)
      assert result == "ID: 101"
    end
  end

  # ---------------------------------------------------------------
  # format_object_list/3
  # ---------------------------------------------------------------

  describe "format_object_list/3" do
    @fields [{"Email", "email"}]

    test "returns 'No X found.' for empty list" do
      assert Helpers.format_object_list([], @fields, "contacts") == "No contacts found."
    end

    test "formats single object with count header" do
      objects = [%{id: "101", properties: %{"email" => "j@example.com"}}]
      result = Helpers.format_object_list(objects, @fields, "contacts")

      assert result =~ "Found 1 contacts:"
      assert result =~ "ID: 101"
      assert result =~ "Email: j@example.com"
    end

    test "separates multiple objects with dividers" do
      objects = [
        %{id: "101", properties: %{"email" => "a@example.com"}},
        %{id: "102", properties: %{"email" => "b@example.com"}}
      ]

      result = Helpers.format_object_list(objects, @fields, "contacts")

      assert result =~ "Found 2 contacts:"
      assert result =~ "---"
      assert result =~ "a@example.com"
      assert result =~ "b@example.com"
    end
  end

  # ---------------------------------------------------------------
  # parse_properties_json/1
  # ---------------------------------------------------------------

  describe "parse_properties_json/1" do
    test "returns empty map for nil" do
      assert {:ok, %{}} = Helpers.parse_properties_json(nil)
    end

    test "returns empty map for empty string" do
      assert {:ok, %{}} = Helpers.parse_properties_json("")
    end

    test "parses valid JSON object" do
      assert {:ok, %{"jobtitle" => "CTO"}} =
               Helpers.parse_properties_json(~s({"jobtitle": "CTO"}))
    end

    test "rejects non-object JSON (array)" do
      assert {:error, message} = Helpers.parse_properties_json("[1, 2, 3]")
      assert message =~ "JSON object"
    end

    test "rejects non-object JSON (string)" do
      assert {:error, message} = Helpers.parse_properties_json(~s("just a string"))
      assert message =~ "JSON object"
    end

    test "rejects invalid JSON" do
      assert {:error, message} = Helpers.parse_properties_json("{not valid json}")
      assert message =~ "Invalid JSON"
    end
  end

  # ---------------------------------------------------------------
  # handle_error/1 (generic errors)
  # ---------------------------------------------------------------

  describe "handle_error/1" do
    test "returns invalid API key message for 401" do
      {:ok, %Result{status: :error, content: content}} =
        Helpers.handle_error({:error, {:api_error, 401, "Unauthorized"}})

      assert content =~ "API key is invalid"
    end

    test "returns rate limit message for 429" do
      {:ok, %Result{status: :error, content: content}} =
        Helpers.handle_error({:error, {:api_error, 429, "Too many requests"}})

      assert content =~ "rate limit"
    end

    test "returns generic API error with message" do
      {:ok, %Result{status: :error, content: content}} =
        Helpers.handle_error({:error, {:api_error, 500, "Internal Server Error"}})

      assert content =~ "HubSpot API error: Internal Server Error"
    end

    test "handles exception in request_failed" do
      exception = %RuntimeError{message: "connection refused"}

      {:ok, %Result{status: :error, content: content}} =
        Helpers.handle_error({:error, {:request_failed, exception}})

      assert content =~ "Failed to reach HubSpot: connection refused"
    end

    test "handles non-exception reason in request_failed" do
      {:ok, %Result{status: :error, content: content}} =
        Helpers.handle_error({:error, {:request_failed, :timeout}})

      assert content =~ "Failed to reach HubSpot:"
      assert content =~ "timeout"
    end
  end

  # ---------------------------------------------------------------
  # handle_error/3 (object-specific errors)
  # ---------------------------------------------------------------

  describe "handle_error/3" do
    test "returns 404 with object type and id" do
      {:ok, %Result{status: :error, content: content}} =
        Helpers.handle_error({:error, {:api_error, 404, "Not found"}}, "contact", "101")

      assert content =~ "No contact found with ID 101"
    end

    test "returns 409 conflict with object type and field" do
      {:ok, %Result{status: :error, content: content}} =
        Helpers.handle_error({:error, {:api_error, 409, "Conflict"}}, "contact", "email")

      assert content =~ "A contact with this email already exists"
    end
  end

  # ---------------------------------------------------------------
  # integration_not_configured/0 and api_key_not_found/0
  # ---------------------------------------------------------------

  describe "integration_not_configured/0" do
    test "returns error Result with configuration message" do
      {:ok, %Result{status: :error, content: content}} = Helpers.integration_not_configured()
      assert content =~ "HubSpot integration not configured"
    end
  end

  describe "api_key_not_found/0" do
    test "returns error Result with API key message" do
      {:ok, %Result{status: :error, content: content}} = Helpers.api_key_not_found()
      assert content =~ "API key not found"
    end
  end
end

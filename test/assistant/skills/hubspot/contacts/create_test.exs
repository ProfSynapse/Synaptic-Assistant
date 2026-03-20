# test/assistant/skills/hubspot/contacts/create_test.exs
#
# Representative handler test for hubspot.create_contact. Uses a MockHubSpot
# module injected via context.integrations[:hubspot] to avoid real API calls.
# Tests integration guard, API key resolution, validation, success, and errors.
#
# Related files:
#   - lib/assistant/skills/hubspot/contacts/create.ex (module under test)
#   - test/assistant/skills/email/read_test.exs (pattern reference)

defmodule Assistant.Skills.HubSpot.Contacts.CreateTest do
  use ExUnit.Case, async: false
  @moduletag :external

  alias Assistant.Skills.HubSpot.Contacts.Create
  alias Assistant.Skills.Context

  # ---------------------------------------------------------------
  # Mock HubSpot Client
  # ---------------------------------------------------------------

  defmodule MockHubSpot do
    @moduledoc false

    def create_contact(_api_key, properties) do
      send(self(), {:hubspot_create_contact, properties})

      case Process.get(:mock_create_response) do
        nil ->
          {:ok,
           %{
             id: "101",
             properties: Map.merge(%{"email" => "default@example.com"}, properties),
             created_at: "2026-01-01T00:00:00Z",
             updated_at: "2026-01-01T00:00:00Z"
           }}

        response ->
          response
      end
    end
  end

  # ---------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------

  setup do
    # Save and configure API key for resolve_api_key
    prev_key = Application.get_env(:assistant, :hubspot_api_key)
    Application.put_env(:assistant, :hubspot_api_key, "pat-test-key")

    # Clear any cached value in IntegrationSettings ETS
    try do
      Assistant.IntegrationSettings.Cache.invalidate_all()
    rescue
      _ -> :ok
    end

    on_exit(fn ->
      if prev_key,
        do: Application.put_env(:assistant, :hubspot_api_key, prev_key),
        else: Application.delete_env(:assistant, :hubspot_api_key)

      try do
        Assistant.IntegrationSettings.Cache.invalidate_all()
      rescue
        _ -> :ok
      end

      Process.delete(:mock_create_response)
    end)

    :ok
  end

  defp build_context(overrides \\ %{}) do
    base = %Context{
      conversation_id: "conv-1",
      execution_id: "exec-1",
      user_id: "user-1",
      integrations: %{hubspot: MockHubSpot},
      metadata: %{}
    }

    Map.merge(base, overrides)
  end

  # ---------------------------------------------------------------
  # Integration guard
  # ---------------------------------------------------------------

  describe "integration not configured" do
    test "returns error when :hubspot not in integrations" do
      context = build_context(%{integrations: %{}})
      {:ok, result} = Create.execute(%{"email" => "j@example.com"}, context)

      assert result.status == :error
      assert result.content =~ "HubSpot integration not configured"
    end
  end

  # ---------------------------------------------------------------
  # API key guard
  # ---------------------------------------------------------------

  describe "API key not found" do
    test "returns error when API key is nil" do
      Application.delete_env(:assistant, :hubspot_api_key)

      {:ok, result} = Create.execute(%{"email" => "j@example.com"}, build_context())

      assert result.status == :error
      assert result.content =~ "API key not found"
    end
  end

  # ---------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------

  describe "validation" do
    test "returns error when email is missing" do
      {:ok, result} = Create.execute(%{}, build_context())

      assert result.status == :error
      assert result.content =~ "Missing required parameter: --email"
    end

    test "returns error when email is empty string" do
      {:ok, result} = Create.execute(%{"email" => ""}, build_context())

      assert result.status == :error
      assert result.content =~ "Missing required parameter: --email"
    end

    test "returns error for invalid properties JSON" do
      flags = %{"email" => "j@example.com", "properties" => "not json"}
      {:ok, result} = Create.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "Invalid JSON"
    end

    test "returns error for non-object properties JSON" do
      flags = %{"email" => "j@example.com", "properties" => "[1,2,3]"}
      {:ok, result} = Create.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "JSON object"
    end
  end

  # ---------------------------------------------------------------
  # Success path
  # ---------------------------------------------------------------

  describe "successful creation" do
    test "creates contact with required email only" do
      flags = %{"email" => "j@example.com"}
      {:ok, result} = Create.execute(flags, build_context())

      assert result.status == :ok
      assert result.content =~ "Contact created successfully"
      assert result.content =~ "j@example.com"
      assert result.side_effects == [:hubspot_contact_created]
      assert result.metadata.contact_id == "101"

      assert_received {:hubspot_create_contact, properties}
      assert properties["email"] == "j@example.com"
    end

    test "creates contact with all optional fields" do
      flags = %{
        "email" => "j@example.com",
        "first_name" => "Jane",
        "last_name" => "Doe",
        "phone" => "555-1234",
        "company" => "Acme Corp"
      }

      {:ok, result} = Create.execute(flags, build_context())
      assert result.status == :ok

      assert_received {:hubspot_create_contact, properties}
      assert properties["email"] == "j@example.com"
      assert properties["firstname"] == "Jane"
      assert properties["lastname"] == "Doe"
      assert properties["phone"] == "555-1234"
      assert properties["company"] == "Acme Corp"
    end

    test "merges extra properties from JSON" do
      flags = %{
        "email" => "j@example.com",
        "properties" => ~s({"jobtitle": "CTO", "lifecyclestage": "lead"})
      }

      {:ok, result} = Create.execute(flags, build_context())
      assert result.status == :ok

      assert_received {:hubspot_create_contact, properties}
      assert properties["email"] == "j@example.com"
      assert properties["jobtitle"] == "CTO"
      assert properties["lifecyclestage"] == "lead"
    end

    test "extra properties override optional flags" do
      flags = %{
        "email" => "j@example.com",
        "first_name" => "Jane",
        "properties" => ~s({"firstname": "Override"})
      }

      {:ok, _result} = Create.execute(flags, build_context())

      assert_received {:hubspot_create_contact, properties}
      # Map.merge(base, extra) — extra wins
      assert properties["firstname"] == "Override"
    end
  end

  # ---------------------------------------------------------------
  # API error handling
  # ---------------------------------------------------------------

  describe "API error handling" do
    test "handles 409 conflict (duplicate email)" do
      Process.put(:mock_create_response, {:error, {:api_error, 409, "Contact already exists"}})

      {:ok, result} = Create.execute(%{"email" => "j@example.com"}, build_context())

      assert result.status == :error
      assert result.content =~ "already exists"
    end

    test "handles 401 invalid API key" do
      Process.put(:mock_create_response, {:error, {:api_error, 401, "Unauthorized"}})

      {:ok, result} = Create.execute(%{"email" => "j@example.com"}, build_context())

      assert result.status == :error
      assert result.content =~ "API key is invalid"
    end

    test "handles 429 rate limit" do
      Process.put(:mock_create_response, {:error, {:api_error, 429, "Rate limit"}})

      {:ok, result} = Create.execute(%{"email" => "j@example.com"}, build_context())

      assert result.status == :error
      assert result.content =~ "rate limit"
    end

    test "handles generic API error" do
      Process.put(:mock_create_response, {:error, {:api_error, 500, "Internal error"}})

      {:ok, result} = Create.execute(%{"email" => "j@example.com"}, build_context())

      assert result.status == :error
      assert result.content =~ "HubSpot API error: Internal error"
    end

    test "handles network failure with exception" do
      Process.put(
        :mock_create_response,
        {:error, {:request_failed, %RuntimeError{message: "connection refused"}}}
      )

      {:ok, result} = Create.execute(%{"email" => "j@example.com"}, build_context())

      assert result.status == :error
      assert result.content =~ "Failed to reach HubSpot"
    end
  end
end

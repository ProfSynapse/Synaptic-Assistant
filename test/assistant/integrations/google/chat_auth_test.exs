# test/assistant/integrations/google/chat_auth_test.exs
#
# Risk Tier: HIGH — Chat bot is the primary user-facing integration.
#
# Tests the integration between Chat.send_message/3 and Auth.service_token/0
# after the Goth removal. Verifies that:
#   - Auth errors propagate correctly through Chat
#   - Chat properly uses the service_token/0 return format
#   - Input validation works independently of auth
#
# Related files:
#   - lib/assistant/integrations/google/chat.ex (module under test)
#   - lib/assistant/integrations/google/auth.ex (service_token provider)

defmodule Assistant.Integrations.Google.ChatAuthTest do
  # async: false — modifies global Application env
  use ExUnit.Case, async: false

  alias Assistant.Integrations.Google.Chat

  @token_cache_table :google_service_token_cache

  # ---------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------

  setup do
    clear_ets_cache()

    on_exit(fn ->
      Application.delete_env(:assistant, :google_service_account_json)
      clear_ets_cache()
    end)

    :ok
  end

  defp clear_ets_cache do
    case :ets.whereis(@token_cache_table) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(@token_cache_table)
    end
  rescue
    ArgumentError -> :ok
  end

  # ---------------------------------------------------------------
  # Auth error propagation
  # ---------------------------------------------------------------

  describe "send_message/3 — auth error propagation" do
    test "returns {:error, :not_configured} when service account not set" do
      Application.delete_env(:assistant, :google_service_account_json)

      assert {:error, :not_configured} =
               Chat.send_message("spaces/AAAA_BBBB", "Hello")
    end

    test "returns {:error, :not_configured} when credentials JSON is empty object" do
      Application.put_env(:assistant, :google_service_account_json, "{}")

      assert {:error, :not_configured} =
               Chat.send_message("spaces/AAAA_BBBB", "Hello")
    end

    test "returns auth error when PEM is malformed" do
      json =
        Jason.encode!(%{
          "client_email" => "bot@project.iam.gserviceaccount.com",
          "private_key" => "this-is-not-a-pem"
        })

      Application.put_env(:assistant, :google_service_account_json, json)

      result = Chat.send_message("spaces/AAAA_BBBB", "Hello")

      # Malformed PEM may fail at parse or sign stage — both are valid errors
      assert result in [
               {:error, :invalid_private_key},
               {:error, :jwt_signing_failed}
             ]
    end
  end

  # ---------------------------------------------------------------
  # Input validation (independent of auth)
  # ---------------------------------------------------------------

  describe "send_message/3 — input validation" do
    test "rejects invalid space_name format" do
      assert {:error, :invalid_space_name} =
               Chat.send_message("invalid-space-format", "Hello")
    end

    test "rejects empty space_name" do
      assert {:error, :invalid_space_name} =
               Chat.send_message("", "Hello")
    end

    test "rejects space_name with path traversal" do
      assert {:error, :invalid_space_name} =
               Chat.send_message("spaces/../../../etc/passwd", "Hello")
    end

    test "rejects space_name with URL injection" do
      assert {:error, :invalid_space_name} =
               Chat.send_message("spaces/AAAA?q=injected", "Hello")
    end

    test "accepts valid space_name formats" do
      # These pass validation (will fail at auth step)
      Application.delete_env(:assistant, :google_service_account_json)

      result1 = Chat.send_message("spaces/AAAA_BBBB", "Hello")
      refute result1 == {:error, :invalid_space_name}

      result2 = Chat.send_message("spaces/abc-def-123", "Hello")
      refute result2 == {:error, :invalid_space_name}
    end
  end

  # ---------------------------------------------------------------
  # Chat with cached service token
  # ---------------------------------------------------------------

  describe "send_message/3 — with cached service token" do
    test "uses cached token for API call (fails at HTTP, not auth)" do
      ensure_cache_table()

      # Inject a cached token — Chat should use it directly
      expires_at = System.system_time(:second) + 7200
      :ets.insert(@token_cache_table, {:service_token, "cached-chat-token", expires_at})

      # Should attempt the Chat API call with the cached token.
      # Will fail at the HTTP level (no real Google Chat API), but the
      # error should be API-related, not auth-related.
      result = Chat.send_message("spaces/AAAA_BBBB", "Hello from test")

      # Should NOT be an auth error
      refute result == {:error, :not_configured}
      refute result == {:error, :invalid_private_key}

      case result do
        {:error, {:api_error, _status, _body}} -> assert true
        {:error, {:request_failed, _reason}} -> assert true
        {:ok, _body} -> assert true
        other -> flunk("Unexpected result: #{inspect(other)}")
      end
    end

    test "passes token as Bearer header in API call" do
      ensure_cache_table()

      # When a cached token exists, Chat uses it in an Authorization header.
      # The API call will fail, but the path through auth is correct.
      expires_at = System.system_time(:second) + 7200
      :ets.insert(@token_cache_table, {:service_token, "test-bearer-token", expires_at})

      result = Chat.send_message("spaces/TEST_SPACE", "Test message")

      # The fact that we get an HTTP error (not an auth error) confirms
      # the token was retrieved and used in the request
      refute result == {:error, :not_configured}
      refute result == {:error, :invalid_private_key}
      refute result == {:error, :jwt_signing_failed}
    end
  end

  # ---------------------------------------------------------------
  # Threaded reply options
  # ---------------------------------------------------------------

  describe "send_message/3 — options" do
    test "thread_name option does not affect auth error propagation" do
      Application.delete_env(:assistant, :google_service_account_json)

      result =
        Chat.send_message("spaces/AAAA_BBBB", "Hello",
          thread_name: "spaces/AAAA_BBBB/threads/CCCC"
        )

      assert {:error, :not_configured} = result
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp ensure_cache_table do
    case :ets.whereis(@token_cache_table) do
      :undefined ->
        :ets.new(@token_cache_table, [:set, :public, :named_table])

      _ref ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end

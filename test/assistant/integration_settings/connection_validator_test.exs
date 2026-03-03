# test/assistant/integration_settings/connection_validator_test.exs
#
# Tests for ConnectionValidator — real API handshake validation per integration.
#
# Uses Bypass to mock HTTP endpoints for Telegram, Discord, Slack, HubSpot,
# and ElevenLabs. Google tests use ETS cache injection (service token) and
# Application.put_env for credential control.
#
# All tests async: false because they modify shared Application env and ETS.
#
# Related files:
#   - lib/assistant/integration_settings/connection_validator.ex (module under test)
#   - test/assistant/integrations/telegram/client_test.exs (pattern reference)

defmodule Assistant.IntegrationSettings.ConnectionValidatorTest do
  use Assistant.DataCase, async: false

  alias Assistant.Auth.TokenStore
  alias Assistant.IntegrationSettings.Cache
  alias Assistant.IntegrationSettings.ConnectionValidator
  alias Assistant.Schemas.User

  @token_cache_table :google_service_token_cache

  # ---------------------------------------------------------------
  # Setup — save and restore env vars, clear ETS
  # ---------------------------------------------------------------

  setup do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"

    # Save previous values
    prev = %{
      telegram_bot_token: Application.get_env(:assistant, :telegram_bot_token),
      telegram_api_base_url: Application.get_env(:assistant, :telegram_api_base_url),
      discord_bot_token: Application.get_env(:assistant, :discord_bot_token),
      discord_api_base_url: Application.get_env(:assistant, :discord_api_base_url),
      slack_bot_token: Application.get_env(:assistant, :slack_bot_token),
      slack_api_base_url: Application.get_env(:assistant, :slack_api_base_url),
      hubspot_api_key: Application.get_env(:assistant, :hubspot_api_key),
      hubspot_api_base_url: Application.get_env(:assistant, :hubspot_api_base_url),
      elevenlabs_api_key: Application.get_env(:assistant, :elevenlabs_api_key),
      elevenlabs_api_base_url: Application.get_env(:assistant, :elevenlabs_api_base_url),
      google_service_account_json: Application.get_env(:assistant, :google_service_account_json),
      google_oauth_client_id: Application.get_env(:assistant, :google_oauth_client_id),
      google_oauth_client_secret: Application.get_env(:assistant, :google_oauth_client_secret)
    }

    # Point all base URLs to Bypass
    Application.put_env(:assistant, :telegram_api_base_url, base_url)
    Application.put_env(:assistant, :discord_api_base_url, base_url)
    Application.put_env(:assistant, :slack_api_base_url, base_url)
    Application.put_env(:assistant, :hubspot_api_base_url, base_url)
    Application.put_env(:assistant, :elevenlabs_api_base_url, base_url)

    # Clear all tokens so tests start from :not_configured
    Application.delete_env(:assistant, :telegram_bot_token)
    Application.delete_env(:assistant, :discord_bot_token)
    Application.delete_env(:assistant, :slack_bot_token)
    Application.delete_env(:assistant, :hubspot_api_key)
    Application.delete_env(:assistant, :elevenlabs_api_key)
    Application.delete_env(:assistant, :google_service_account_json)

    clear_ets_cache()

    # Clear the IntegrationSettings ETS cache to prevent leaking values
    # from other tests (e.g., cache_test puts :slack_bot_token into ETS).
    Cache.invalidate_all()

    # Catch-all stub for any unexpected routes hit by parallel validators.
    # validate_all/1 runs all 7 validators, so integration-specific tests may
    # trigger routes for other integrations that aren't the test's focus.
    Bypass.stub(bypass, :any, :any, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(503, Jason.encode!(%{"error" => "stub"}))
    end)

    on_exit(fn ->
      # Restore all previous values
      Enum.each(prev, fn {key, value} ->
        if value do
          Application.put_env(:assistant, key, value)
        else
          Application.delete_env(:assistant, key)
        end
      end)

      clear_ets_cache()
      Cache.invalidate_all()
    end)

    %{bypass: bypass, base_url: base_url}
  end

  defp clear_ets_cache do
    case :ets.whereis(@token_cache_table) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(@token_cache_table)
    end
  rescue
    ArgumentError -> :ok
  end

  defp ensure_cache_table do
    case :ets.whereis(@token_cache_table) do
      :undefined -> :ets.new(@token_cache_table, [:set, :public, :named_table])
      _ref -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  # ---------------------------------------------------------------
  # Telegram
  # ---------------------------------------------------------------

  describe "telegram validation" do
    test "returns :not_configured when bot token is nil" do
      results = ConnectionValidator.validate_all(nil)
      assert results["telegram"] == :not_configured
    end

    test "returns :connected on successful getMe", %{bypass: bypass} do
      Application.put_env(:assistant, :telegram_bot_token, "test-token")

      Bypass.expect(bypass, "GET", "/bottest-token/getMe", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => %{"id" => 123}}))
      end)

      results = ConnectionValidator.validate_all(nil)
      assert results["telegram"] == :connected
    end

    test "returns :not_connected on API error", %{bypass: bypass} do
      Application.put_env(:assistant, :telegram_bot_token, "bad-token")

      Bypass.expect(bypass, "GET", "/botbad-token/getMe", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(401, Jason.encode!(%{"ok" => false, "description" => "Unauthorized"}))
      end)

      results = ConnectionValidator.validate_all(nil)
      assert results["telegram"] == :not_connected
    end
  end

  # ---------------------------------------------------------------
  # Discord
  # ---------------------------------------------------------------

  describe "discord validation" do
    test "returns :not_configured when bot token is nil" do
      results = ConnectionValidator.validate_all(nil)
      assert results["discord"] == :not_configured
    end

    test "returns :connected on successful gateway response", %{bypass: bypass} do
      Application.put_env(:assistant, :discord_bot_token, "test-discord-token")

      Bypass.expect(bypass, "GET", "/gateway", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"url" => "wss://gateway.discord.gg"}))
      end)

      results = ConnectionValidator.validate_all(nil)
      assert results["discord"] == :connected
    end

    test "returns :not_connected on API error", %{bypass: bypass} do
      Application.put_env(:assistant, :discord_bot_token, "bad-discord-token")

      Bypass.expect(bypass, "GET", "/gateway", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(401, Jason.encode!(%{"message" => "401: Unauthorized"}))
      end)

      results = ConnectionValidator.validate_all(nil)
      assert results["discord"] == :not_connected
    end
  end

  # ---------------------------------------------------------------
  # Slack
  # ---------------------------------------------------------------

  describe "slack validation" do
    test "returns :not_configured when bot token is nil" do
      results = ConnectionValidator.validate_all(nil)
      assert results["slack"] == :not_configured
    end

    test "returns :connected on successful auth.test", %{bypass: bypass} do
      Application.put_env(:assistant, :slack_bot_token, "xoxb-test-token")

      Bypass.expect(bypass, "POST", "/auth.test", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"ok" => true, "team" => "test", "user" => "bot"})
        )
      end)

      results = ConnectionValidator.validate_all(nil)
      assert results["slack"] == :connected
    end

    test "returns :not_connected on API error", %{bypass: bypass} do
      Application.put_env(:assistant, :slack_bot_token, "xoxb-bad-token")

      Bypass.expect(bypass, "POST", "/auth.test", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => false, "error" => "invalid_auth"}))
      end)

      results = ConnectionValidator.validate_all(nil)
      assert results["slack"] == :not_connected
    end
  end

  # ---------------------------------------------------------------
  # HubSpot
  # ---------------------------------------------------------------

  describe "hubspot validation" do
    test "returns :not_configured when API key is nil" do
      results = ConnectionValidator.validate_all(nil)
      assert results["hubspot"] == :not_configured
    end

    test "returns :connected on 200 response", %{bypass: bypass} do
      Application.put_env(:assistant, :hubspot_api_key, "pat-test-key")

      Bypass.expect(bypass, "GET", "/crm/v3/objects/contacts", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"results" => []}))
      end)

      results = ConnectionValidator.validate_all(nil)
      assert results["hubspot"] == :connected
    end

    test "returns :not_connected on 401 response", %{bypass: bypass} do
      Application.put_env(:assistant, :hubspot_api_key, "pat-bad-key")

      Bypass.expect(bypass, "GET", "/crm/v3/objects/contacts", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(401, Jason.encode!(%{"message" => "Unauthorized"}))
      end)

      results = ConnectionValidator.validate_all(nil)
      assert results["hubspot"] == :not_connected
    end
  end

  # ---------------------------------------------------------------
  # ElevenLabs
  # ---------------------------------------------------------------

  describe "elevenlabs validation" do
    test "returns :not_configured when API key is nil" do
      results = ConnectionValidator.validate_all(nil)
      assert results["elevenlabs"] == :not_configured
    end

    test "returns :connected on 200 response", %{bypass: bypass} do
      Application.put_env(:assistant, :elevenlabs_api_key, "el-test-key")

      Bypass.expect(bypass, "GET", "/v1/user", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"xi_api_key" => "el-test-key", "is_new_user" => false})
        )
      end)

      results = ConnectionValidator.validate_all(nil)
      assert results["elevenlabs"] == :connected
    end

    test "returns :not_connected on 401 response", %{bypass: bypass} do
      Application.put_env(:assistant, :elevenlabs_api_key, "el-bad-key")

      Bypass.expect(bypass, "GET", "/v1/user", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          401,
          Jason.encode!(%{"detail" => %{"message" => "Unauthorized"}})
        )
      end)

      results = ConnectionValidator.validate_all(nil)
      assert results["elevenlabs"] == :not_connected
    end
  end

  # ---------------------------------------------------------------
  # Google Workspace (user_token)
  # ---------------------------------------------------------------

  describe "google_workspace validation" do
    test "returns :not_configured when user_id is nil" do
      results = ConnectionValidator.validate_all(nil)
      assert results["google_workspace"] == :not_configured
    end

    test "returns :connected when user has valid OAuth token", %{bypass: bypass} do
      user = insert_test_user()
      insert_valid_google_token(user.id)

      # Stub bypass for any parallel validators that may fire
      Bypass.stub(bypass, :any, :any, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, Jason.encode!(%{"error" => "stub"}))
      end)

      results = ConnectionValidator.validate_all(user.id)
      assert results["google_workspace"] == :connected
    end

    test "returns :not_configured when user has no OAuth token row", %{bypass: bypass} do
      user = insert_test_user()

      Bypass.stub(bypass, :any, :any, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, Jason.encode!(%{"error" => "stub"}))
      end)

      results = ConnectionValidator.validate_all(user.id)
      assert results["google_workspace"] == :not_configured
    end

    test "returns :not_connected when token is expired and refresh fails", %{bypass: bypass} do
      user = insert_test_user()
      insert_expired_google_token(user.id)

      # Ensure OAuth client credentials are NOT configured so refresh fails.
      # Auth.OAuth.refresh_access_token needs client_id + client_secret.
      Application.delete_env(:assistant, :google_oauth_client_id)
      Application.delete_env(:assistant, :google_oauth_client_secret)

      Bypass.stub(bypass, :any, :any, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, Jason.encode!(%{"error" => "stub"}))
      end)

      results = ConnectionValidator.validate_all(user.id)
      assert results["google_workspace"] == :not_connected
    end
  end

  # ---------------------------------------------------------------
  # Google Chat (service_token)
  # ---------------------------------------------------------------

  describe "google_chat validation" do
    test "returns :not_configured when service account credentials missing" do
      Application.delete_env(:assistant, :google_service_account_json)
      results = ConnectionValidator.validate_all(nil)
      assert results["google_chat"] == :not_configured
    end

    test "returns :connected when service token is cached in ETS" do
      ensure_cache_table()
      expires_at = System.system_time(:second) + 7200
      :ets.insert(@token_cache_table, {:service_token, "cached-token", expires_at})

      results = ConnectionValidator.validate_all(nil)
      assert results["google_chat"] == :connected
    end

    test "returns :not_connected when service account credentials are invalid" do
      # Provide JSON with required fields but an invalid private key.
      # Auth.service_token() parses credentials OK, but JOSE.JWK.from_pem
      # fails → {:error, :invalid_private_key} → validator maps to :not_connected.
      bad_creds =
        Jason.encode!(%{
          "client_email" => "test@test.iam.gserviceaccount.com",
          "private_key" => "not-a-valid-pem-key"
        })

      Application.put_env(:assistant, :google_service_account_json, bad_creds)
      # Clear ETS cache so it actually fetches a new token
      clear_ets_cache()

      results = ConnectionValidator.validate_all(nil)
      assert results["google_chat"] == :not_connected
    end
  end

  # ---------------------------------------------------------------
  # validate_all/1 — integration
  # ---------------------------------------------------------------

  describe "validate_all/1 integration" do
    test "returns a map with all 7 integration groups" do
      results = ConnectionValidator.validate_all(nil)

      assert Map.has_key?(results, "google_workspace")
      assert Map.has_key?(results, "telegram")
      assert Map.has_key?(results, "slack")
      assert Map.has_key?(results, "discord")
      assert Map.has_key?(results, "google_chat")
      assert Map.has_key?(results, "hubspot")
      assert Map.has_key?(results, "elevenlabs")
      assert map_size(results) == 7
    end

    test "all results are valid status atoms" do
      results = ConnectionValidator.validate_all(nil)

      Enum.each(results, fn {_group, status} ->
        assert status in [:connected, :not_connected, :not_configured]
      end)
    end

    test "returns :not_configured for all when no keys set" do
      results = ConnectionValidator.validate_all(nil)

      # All should be :not_configured since setup clears all tokens
      Enum.each(results, fn {_group, status} ->
        assert status == :not_configured,
               "Expected :not_configured for all groups, got #{inspect(results)}"
      end)
    end

    test "handles mixed connected and not_configured", %{bypass: bypass} do
      # Configure only Telegram
      Application.put_env(:assistant, :telegram_bot_token, "test-token")

      Bypass.expect(bypass, "GET", "/bottest-token/getMe", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => %{"id" => 123}}))
      end)

      results = ConnectionValidator.validate_all(nil)

      assert results["telegram"] == :connected
      assert results["discord"] == :not_configured
      assert results["slack"] == :not_configured
      assert results["hubspot"] == :not_configured
      assert results["elevenlabs"] == :not_configured
    end
  end

  # ---------------------------------------------------------------
  # Error resilience
  # ---------------------------------------------------------------

  describe "error resilience" do
    test "returns :not_connected when server is down", %{bypass: bypass} do
      Application.put_env(:assistant, :elevenlabs_api_key, "el-down-key")

      # Shut down Bypass to simulate unreachable server
      Bypass.down(bypass)

      results = ConnectionValidator.validate_all(nil)
      assert results["elevenlabs"] == :not_connected
    end

    test "returns :not_connected when validator raises an exception" do
      Application.put_env(:assistant, :hubspot_api_key, "pat-crash-key")

      # Set HubSpot base URL to an invalid scheme so Req.get raises ArgumentError.
      # This exercises the rescue clause in validate_all/1 (lines 76-82).
      Application.put_env(:assistant, :hubspot_api_base_url, "://invalid")

      results = ConnectionValidator.validate_all(nil)
      assert results["hubspot"] == :not_connected
    end

    test "returns :not_connected when validator exceeds timeout" do
      Application.put_env(:assistant, :elevenlabs_api_key, "el-slow-key")

      # Point ElevenLabs at a separate Bypass that sleeps beyond the 5s
      # Task.async_stream timeout. We use a dedicated Bypass (not the shared
      # one) so its teardown doesn't affect other validators' Bypass port.
      slow_bypass = Bypass.open()

      Application.put_env(
        :assistant,
        :elevenlabs_api_base_url,
        "http://localhost:#{slow_bypass.port}"
      )

      # Use stub (not expect) — Bypass won't fail verification when the
      # connection is killed by Task.async_stream's on_timeout: :kill_task.
      # Trap exits so the handler process exits cleanly instead of propagating
      # shutdown to the test process.
      Bypass.stub(slow_bypass, "GET", "/v1/user", fn conn ->
        Process.flag(:trap_exit, true)

        receive do
          {:EXIT, _, _} -> :ok
        after
          6_000 -> :ok
        end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true}))
      end)

      results = ConnectionValidator.validate_all(nil)
      assert results["elevenlabs"] == :not_connected
    end
  end

  # ---------------------------------------------------------------
  # Test helpers — DB fixtures for Google Workspace tests
  # ---------------------------------------------------------------

  defp insert_test_user do
    %User{}
    |> User.changeset(%{
      external_id: "test-google-user-#{System.unique_integer([:positive])}",
      channel: "google_chat",
      display_name: "Test User"
    })
    |> Repo.insert!()
  end

  defp insert_valid_google_token(user_id) do
    TokenStore.upsert_google_token(user_id, %{
      refresh_token: "fake-refresh-token",
      access_token: "fake-valid-access-token",
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      provider_email: "test@example.com"
    })
  end

  defp insert_expired_google_token(user_id) do
    TokenStore.upsert_google_token(user_id, %{
      refresh_token: "fake-refresh-token",
      access_token: "fake-expired-access-token",
      token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second),
      provider_email: "test@example.com"
    })
  end
end

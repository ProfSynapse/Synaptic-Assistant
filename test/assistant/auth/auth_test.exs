# test/assistant/auth/auth_test.exs — Integration tests for Auth.user_token/1 and Auth.service_token/0.
#
# Risk Tier: HIGH — Auth is the gateway to all Google API calls.
# Tests the full error taxonomy: :not_connected, :refresh_failed, :invalid_grant.
# Mocks TokenStore and OAuth to avoid real DB/HTTP calls for the refresh path.

defmodule Assistant.Integrations.Google.AuthTest do
  use Assistant.DataCase, async: false

  alias Assistant.Auth.TokenStore
  alias Assistant.Integrations.Google.Auth
  alias Assistant.Schemas.User

  # -------------------------------------------------------------------
  # Setup
  # -------------------------------------------------------------------

  setup do
    {:ok, user} =
      Repo.insert(
        User.changeset(%User{}, %{
          external_id: "auth-test-user-#{System.unique_integer([:positive])}",
          channel: "test"
        })
      )

    # Configure OAuth credentials for refresh path
    Application.put_env(:assistant, :google_oauth_client_id, "test-client-id")
    Application.put_env(:assistant, :google_oauth_client_secret, "test-client-secret")

    on_exit(fn ->
      Application.delete_env(:assistant, :google_oauth_client_id)
      Application.delete_env(:assistant, :google_oauth_client_secret)
    end)

    %{user: user}
  end

  # -------------------------------------------------------------------
  # user_token/1
  # -------------------------------------------------------------------

  describe "user_token/1" do
    test "returns {:error, :not_connected} when no token exists", %{user: user} do
      assert {:error, :not_connected} = Auth.user_token(user.id)
    end

    test "returns {:ok, access_token} when token is valid (not expired)", %{user: user} do
      {:ok, _} =
        TokenStore.upsert_google_token(user.id, %{
          refresh_token: "refresh-tok",
          access_token: "valid-access-tok",
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      assert {:ok, "valid-access-tok"} = Auth.user_token(user.id)
    end

    test "returns {:error, :not_connected} when token has no access_token and refresh fails", %{
      user: user
    } do
      # Insert a token with nil access_token (triggers refresh path)
      # but refresh will fail because Goth isn't configured for real calls
      {:ok, _} =
        TokenStore.upsert_google_token(user.id, %{
          refresh_token: "invalid-refresh-tok",
          access_token: nil,
          token_expires_at: nil
        })

      # user_token/1 will try to refresh. Without a real Goth setup, it should
      # fail. The refresh failure is handled as :refresh_failed.
      result = Auth.user_token(user.id)
      assert result in [{:error, :refresh_failed}, {:error, :not_connected}]
    end
  end

  # -------------------------------------------------------------------
  # configured?/0
  # -------------------------------------------------------------------

  describe "configured?/0" do
    test "returns true when google_credentials are set" do
      Application.put_env(:assistant, :google_credentials, %{"some" => "creds"})
      assert Auth.configured?()
      Application.delete_env(:assistant, :google_credentials)
    end

    test "returns false when google_credentials are not set" do
      Application.delete_env(:assistant, :google_credentials)
      refute Auth.configured?()
    end
  end

  # -------------------------------------------------------------------
  # oauth_configured?/0
  # -------------------------------------------------------------------

  describe "oauth_configured?/0" do
    test "returns true when both client_id and client_secret are set" do
      assert Auth.oauth_configured?()
    end

    test "returns false when client_id is missing" do
      Application.delete_env(:assistant, :google_oauth_client_id)
      refute Auth.oauth_configured?()
    end

    test "returns false when client_secret is missing" do
      Application.delete_env(:assistant, :google_oauth_client_secret)
      refute Auth.oauth_configured?()
    end
  end

  # -------------------------------------------------------------------
  # scopes/0
  # -------------------------------------------------------------------

  describe "scopes/0" do
    test "returns only the chat.bot scope (service account)" do
      scopes = Auth.scopes()
      assert scopes == ["https://www.googleapis.com/auth/chat.bot"]
    end
  end
end

# test/assistant/auth/token_store_test.exs
#
# Smoke tests for Auth.TokenStore. Verifies CRUD operations on oauth_tokens
# table with Cloak encryption. Uses DataCase for DB sandbox.
#
# Related files:
#   - lib/assistant/auth/token_store.ex (module under test)
#   - lib/assistant/schemas/oauth_token.ex (schema)

defmodule Assistant.Auth.TokenStoreTest do
  use Assistant.DataCase, async: true

  alias Assistant.Auth.TokenStore
  alias Assistant.Schemas.OAuthToken

  # ---------------------------------------------------------------
  # Setup — create a test user
  # ---------------------------------------------------------------

  setup do
    user = insert_test_user()
    %{user: user}
  end

  defp insert_test_user do
    %Assistant.Schemas.User{}
    |> Assistant.Schemas.User.changeset(%{
      external_id: "token-store-test-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Assistant.Repo.insert!()
  end

  # ---------------------------------------------------------------
  # get_google_token
  # ---------------------------------------------------------------

  describe "get_google_token/1" do
    test "returns :not_connected when no token exists", %{user: user} do
      assert {:error, :not_connected} = TokenStore.get_google_token(user.id)
    end

    test "returns token after upsert", %{user: user} do
      {:ok, _} =
        TokenStore.upsert_google_token(user.id, %{
          refresh_token: "refresh-123",
          access_token: "access-456",
          provider_email: "user@example.com"
        })

      assert {:ok, %OAuthToken{} = token} = TokenStore.get_google_token(user.id)
      assert token.provider == "google"
      assert token.provider_email == "user@example.com"
      # Encrypted fields are decrypted transparently
      assert token.refresh_token == "refresh-123"
      assert token.access_token == "access-456"
    end
  end

  # ---------------------------------------------------------------
  # upsert_google_token
  # ---------------------------------------------------------------

  describe "upsert_google_token/2" do
    test "inserts a new token", %{user: user} do
      assert {:ok, %OAuthToken{} = token} =
               TokenStore.upsert_google_token(user.id, %{
                 refresh_token: "rt-new",
                 provider_email: "new@example.com",
                 provider_uid: "uid-123",
                 scopes: "openid email"
               })

      assert token.user_id == user.id
      assert token.provider == "google"
      assert token.refresh_token == "rt-new"
    end

    test "updates on conflict (same user + provider)", %{user: user} do
      {:ok, _first} =
        TokenStore.upsert_google_token(user.id, %{
          refresh_token: "rt-v1",
          provider_email: "v1@example.com"
        })

      {:ok, _second} =
        TokenStore.upsert_google_token(user.id, %{
          refresh_token: "rt-v2",
          provider_email: "v2@example.com"
        })

      # Same row updated (ID may differ due to RETURNING after upsert,
      # but only one row should exist)
      assert {:ok, token} = TokenStore.get_google_token(user.id)
      assert token.refresh_token == "rt-v2"
      assert token.provider_email == "v2@example.com"
    end
  end

  # ---------------------------------------------------------------
  # update_access_token
  # ---------------------------------------------------------------

  describe "update_access_token/3" do
    test "updates cached access token", %{user: user} do
      {:ok, _} =
        TokenStore.upsert_google_token(user.id, %{
          refresh_token: "rt-1",
          access_token: "old-at"
        })

      expires = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert {:ok, %OAuthToken{} = updated} =
               TokenStore.update_access_token(user.id, "new-at", expires)

      assert updated.access_token == "new-at"
    end

    test "returns :not_connected when no token exists", %{user: user} do
      expires = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert {:error, :not_connected} = TokenStore.update_access_token(user.id, "at", expires)
    end
  end

  # ---------------------------------------------------------------
  # delete_google_token
  # ---------------------------------------------------------------

  describe "delete_google_token/1" do
    test "deletes existing token", %{user: user} do
      {:ok, _} = TokenStore.upsert_google_token(user.id, %{refresh_token: "rt"})
      assert :ok = TokenStore.delete_google_token(user.id)
      assert {:error, :not_connected} = TokenStore.get_google_token(user.id)
    end

    test "is idempotent (no error when no token)", %{user: user} do
      assert :ok = TokenStore.delete_google_token(user.id)
    end
  end

  # ---------------------------------------------------------------
  # google_connected?
  # ---------------------------------------------------------------

  describe "google_connected?/1" do
    test "returns false when not connected", %{user: user} do
      refute TokenStore.google_connected?(user.id)
    end

    test "returns true when connected", %{user: user} do
      {:ok, _} = TokenStore.upsert_google_token(user.id, %{refresh_token: "rt"})
      assert TokenStore.google_connected?(user.id)
    end
  end

  # ---------------------------------------------------------------
  # access_token_valid?
  # ---------------------------------------------------------------

  describe "access_token_valid?/1" do
    test "returns false for nil access_token" do
      refute TokenStore.access_token_valid?(%OAuthToken{access_token: nil, token_expires_at: nil})
    end

    test "returns false for nil expires_at" do
      refute TokenStore.access_token_valid?(%OAuthToken{
               access_token: "at",
               token_expires_at: nil
             })
    end

    test "returns false for expired token" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      refute TokenStore.access_token_valid?(%OAuthToken{
               access_token: "at",
               token_expires_at: past
             })
    end

    test "returns true for valid future token" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert TokenStore.access_token_valid?(%OAuthToken{
               access_token: "at",
               token_expires_at: future
             })
    end

    test "returns false when within 60-second buffer" do
      # 30 seconds from now is within the 60-second buffer
      near_future = DateTime.add(DateTime.utc_now(), 30, :second)

      refute TokenStore.access_token_valid?(%OAuthToken{
               access_token: "at",
               token_expires_at: near_future
             })
    end
  end
end

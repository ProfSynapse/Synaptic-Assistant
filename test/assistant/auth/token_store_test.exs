# test/assistant/auth/token_store_test.exs — TokenStore CRUD + token_valid? tests.
#
# Risk Tier: HIGH — Token storage handles encrypted credentials.
# Tests cover get/upsert/delete, encryption round-trip, and validity checks.

defmodule Assistant.Auth.TokenStoreTest do
  use Assistant.DataCase, async: false

  alias Assistant.Auth.TokenStore
  alias Assistant.Schemas.OAuthToken
  alias Assistant.Schemas.User

  # -------------------------------------------------------------------
  # Setup — create a test user
  # -------------------------------------------------------------------

  setup do
    {:ok, user} =
      Repo.insert(
        User.changeset(%User{}, %{
          external_id: "ts-test-user-#{System.unique_integer([:positive])}",
          channel: "test"
        })
      )

    %{user: user}
  end

  # -------------------------------------------------------------------
  # get_token/2
  # -------------------------------------------------------------------

  describe "get_token/2" do
    test "returns {:error, :not_found} when no token exists", %{user: user} do
      assert {:error, :not_found} = TokenStore.get_token(user.id)
    end

    test "returns {:ok, token} when token exists", %{user: user} do
      {:ok, _} = insert_oauth_token(user.id)

      assert {:ok, %OAuthToken{} = token} = TokenStore.get_token(user.id)
      assert token.user_id == user.id
      assert token.provider == "google"
    end

    test "defaults to 'google' provider", %{user: user} do
      {:ok, _} = insert_oauth_token(user.id)

      assert {:ok, _} = TokenStore.get_token(user.id)
      assert {:ok, _} = TokenStore.get_token(user.id, "google")
    end

    test "returns decrypted tokens (Cloak round-trip)", %{user: user} do
      {:ok, _} = insert_oauth_token(user.id, refresh_token: "my-secret-refresh")

      {:ok, token} = TokenStore.get_token(user.id)
      assert token.refresh_token == "my-secret-refresh"
    end
  end

  # -------------------------------------------------------------------
  # upsert_token/1
  # -------------------------------------------------------------------

  describe "upsert_token/1" do
    test "inserts a new token", %{user: user} do
      attrs = base_token_attrs(user.id)
      assert {:ok, %OAuthToken{} = token} = TokenStore.upsert_token(attrs)

      assert token.user_id == user.id
      assert token.provider == "google"
      assert token.refresh_token == "refresh-tok-123"
    end

    test "upserts on conflict (same user + provider)", %{user: user} do
      attrs1 = base_token_attrs(user.id)
      {:ok, token1} = TokenStore.upsert_token(attrs1)

      attrs2 =
        base_token_attrs(user.id)
        |> Map.put(:access_token, "new-access-tok")
        |> Map.put(:provider_email, "updated@example.com")

      {:ok, token2} = TokenStore.upsert_token(attrs2)

      # Should be the same row (upsert, not insert)
      assert token1.id == token2.id
      assert token2.access_token == "new-access-tok"
      assert token2.provider_email == "updated@example.com"
    end

    test "preserves existing refresh_token on upsert when same value re-submitted", %{user: user} do
      attrs1 = base_token_attrs(user.id) |> Map.put(:refresh_token, "original-refresh")
      {:ok, _} = TokenStore.upsert_token(attrs1)

      # The changeset requires refresh_token, so we must pass one.
      # Verify the value roundtrips correctly through upsert + encryption.
      attrs2 = %{
        user_id: user.id,
        provider: "google",
        refresh_token: "original-refresh",
        access_token: "new-access",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      {:ok, token2} = TokenStore.upsert_token(attrs2)
      assert token2.refresh_token == "original-refresh"
      assert token2.access_token == "new-access"
    end

    test "returns changeset error when refresh_token is omitted", %{user: user} do
      # The changeset requires refresh_token — omitting it causes validation failure
      attrs = %{
        user_id: user.id,
        provider: "google",
        access_token: "access-tok"
      }

      assert {:error, %Ecto.Changeset{}} = TokenStore.upsert_token(attrs)
    end

    test "updates refresh_token when provided in upsert", %{user: user} do
      {:ok, _} = insert_oauth_token(user.id, refresh_token: "old-refresh")

      {:ok, token2} =
        TokenStore.upsert_token(%{
          user_id: user.id,
          provider: "google",
          refresh_token: "new-refresh",
          access_token: "new-access"
        })

      assert token2.refresh_token == "new-refresh"
    end

    test "stores provider_uid and provider_email", %{user: user} do
      attrs =
        base_token_attrs(user.id)
        |> Map.put(:provider_uid, "google-sub-123")
        |> Map.put(:provider_email, "user@gmail.com")

      {:ok, token} = TokenStore.upsert_token(attrs)
      assert token.provider_uid == "google-sub-123"
      assert token.provider_email == "user@gmail.com"
    end

    test "stores scopes", %{user: user} do
      attrs = base_token_attrs(user.id) |> Map.put(:scopes, "openid email profile")
      {:ok, token} = TokenStore.upsert_token(attrs)
      assert token.scopes == "openid email profile"
    end
  end

  # -------------------------------------------------------------------
  # delete_token/2
  # -------------------------------------------------------------------

  describe "delete_token/2" do
    test "deletes an existing token", %{user: user} do
      {:ok, _} = insert_oauth_token(user.id)

      assert {:ok, %OAuthToken{}} = TokenStore.delete_token(user.id)
      assert {:error, :not_found} = TokenStore.get_token(user.id)
    end

    test "returns {:error, :not_found} when no token exists", %{user: user} do
      assert {:error, :not_found} = TokenStore.delete_token(user.id)
    end
  end

  # -------------------------------------------------------------------
  # token_valid?/1
  # -------------------------------------------------------------------

  describe "token_valid?/1" do
    test "returns false for nil access_token" do
      token = %OAuthToken{access_token: nil, token_expires_at: future_datetime()}
      refute TokenStore.token_valid?(token)
    end

    test "returns false for nil token_expires_at" do
      token = %OAuthToken{access_token: "tok", token_expires_at: nil}
      refute TokenStore.token_valid?(token)
    end

    test "returns true for valid (non-expired with buffer) token" do
      token = %OAuthToken{
        access_token: "tok",
        token_expires_at: DateTime.add(DateTime.utc_now(), 120, :second)
      }

      assert TokenStore.token_valid?(token)
    end

    test "returns false for token expiring within 60-second buffer" do
      token = %OAuthToken{
        access_token: "tok",
        token_expires_at: DateTime.add(DateTime.utc_now(), 30, :second)
      }

      refute TokenStore.token_valid?(token)
    end

    test "returns false for expired token" do
      token = %OAuthToken{
        access_token: "tok",
        token_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      }

      refute TokenStore.token_valid?(token)
    end

    test "returns true for token well beyond buffer (65 seconds)" do
      # Buffer is 60 seconds, so 65 seconds out should be valid.
      # Using 65 instead of 61 to avoid timing edge cases.
      token = %OAuthToken{
        access_token: "tok",
        token_expires_at: DateTime.add(DateTime.utc_now(), 65, :second)
      }

      assert TokenStore.token_valid?(token)
    end

    test "returns false for token at exactly 60 seconds (equals buffer)" do
      # DateTime.diff(expires_at, now) > 60 — at 60 it should be false
      token = %OAuthToken{
        access_token: "tok",
        token_expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
      }

      refute TokenStore.token_valid?(token)
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp base_token_attrs(user_id) do
    %{
      user_id: user_id,
      provider: "google",
      refresh_token: "refresh-tok-123",
      access_token: "access-tok-123",
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    }
  end

  defp insert_oauth_token(user_id, overrides \\ []) do
    attrs =
      base_token_attrs(user_id)
      |> Map.merge(Map.new(overrides))

    TokenStore.upsert_token(attrs)
  end

  defp future_datetime do
    DateTime.add(DateTime.utc_now(), 3600, :second)
  end
end

# test/assistant/auth/token_isolation_test.exs
#
# P0 security tests: per-user token isolation and encryption verification.
# Verifies that User A cannot access User B's tokens and that encrypted
# fields roundtrip correctly through the database.
#
# Related files:
#   - lib/assistant/auth/token_store.ex (module under test)
#   - lib/assistant/schemas/oauth_token.ex (schema with Cloak encryption)

defmodule Assistant.Auth.TokenIsolationTest do
  use Assistant.DataCase, async: true

  alias Assistant.Auth.TokenStore

  # ---------------------------------------------------------------
  # Setup — create two test users
  # ---------------------------------------------------------------

  setup do
    user_a = insert_test_user("isolation-a")
    user_b = insert_test_user("isolation-b")
    %{user_a: user_a, user_b: user_b}
  end

  defp insert_test_user(prefix) do
    %Assistant.Schemas.User{}
    |> Assistant.Schemas.User.changeset(%{
      external_id: "#{prefix}-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Repo.insert!()
  end

  # ---------------------------------------------------------------
  # Per-user token isolation
  # ---------------------------------------------------------------

  describe "per-user token isolation" do
    test "User A cannot see User B's token", %{user_a: user_a, user_b: user_b} do
      {:ok, _} =
        TokenStore.upsert_google_token(user_a.id, %{
          refresh_token: "rt-user-a",
          access_token: "at-user-a",
          provider_email: "a@example.com"
        })

      {:ok, _} =
        TokenStore.upsert_google_token(user_b.id, %{
          refresh_token: "rt-user-b",
          access_token: "at-user-b",
          provider_email: "b@example.com"
        })

      {:ok, token_a} = TokenStore.get_google_token(user_a.id)
      assert token_a.refresh_token == "rt-user-a"
      assert token_a.provider_email == "a@example.com"

      {:ok, token_b} = TokenStore.get_google_token(user_b.id)
      assert token_b.refresh_token == "rt-user-b"
      assert token_b.provider_email == "b@example.com"

      assert token_a.id != token_b.id
    end

    test "deleting User A's token does not affect User B", %{user_a: user_a, user_b: user_b} do
      {:ok, _} = TokenStore.upsert_google_token(user_a.id, %{refresh_token: "rt-a"})
      {:ok, _} = TokenStore.upsert_google_token(user_b.id, %{refresh_token: "rt-b"})

      :ok = TokenStore.delete_google_token(user_a.id)

      assert {:error, :not_connected} = TokenStore.get_google_token(user_a.id)
      assert {:ok, _} = TokenStore.get_google_token(user_b.id)
    end

    test "User A's connected? status independent of User B", %{user_a: user_a, user_b: user_b} do
      {:ok, _} = TokenStore.upsert_google_token(user_a.id, %{refresh_token: "rt-a"})

      assert TokenStore.google_connected?(user_a.id)
      refute TokenStore.google_connected?(user_b.id)
    end
  end

  # ---------------------------------------------------------------
  # Encryption roundtrip verification
  # ---------------------------------------------------------------

  describe "encryption roundtrip" do
    test "refresh_token is encrypted at rest and decrypted on read", %{user_a: user} do
      plaintext_refresh = "1//0g-refresh-token-very-secret"
      plaintext_access = "ya29.access-token-also-secret"

      {:ok, _} =
        TokenStore.upsert_google_token(user.id, %{
          refresh_token: plaintext_refresh,
          access_token: plaintext_access,
          provider_email: "enc@example.com"
        })

      {:ok, token} = TokenStore.get_google_token(user.id)
      assert token.refresh_token == plaintext_refresh
      assert token.access_token == plaintext_access

      raw_row =
        Repo.one(
          from(t in "oauth_tokens",
            where: t.user_id == type(^user.id, :binary_id),
            select: %{refresh_token: t.refresh_token, access_token: t.access_token}
          )
        )

      assert raw_row.refresh_token != plaintext_refresh
      assert raw_row.access_token != plaintext_access
      assert is_binary(raw_row.refresh_token)
      assert is_binary(raw_row.access_token)
    end

    test "access_token update preserves encryption", %{user_a: user} do
      {:ok, _} =
        TokenStore.upsert_google_token(user.id, %{
          refresh_token: "rt-1",
          access_token: "old-at"
        })

      new_access = "ya29.brand-new-access-token"
      expires = DateTime.add(DateTime.utc_now(), 3600, :second)
      {:ok, updated} = TokenStore.update_access_token(user.id, new_access, expires)

      assert updated.access_token == new_access

      raw_row =
        Repo.one(
          from(t in "oauth_tokens",
            where: t.user_id == type(^user.id, :binary_id),
            select: %{access_token: t.access_token}
          )
        )

      assert raw_row.access_token != new_access
      assert is_binary(raw_row.access_token)
    end
  end
end

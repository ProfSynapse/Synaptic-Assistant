# test/assistant/auth/magic_link_test.exs
#
# Smoke tests for Auth.MagicLink. Verifies validate/consume/cleanup lifecycle
# by inserting auth_token records directly (bypassing generate/3 which requires
# the OAuth URL builder). Tests cover token lookup, expiry, single-use
# consumption, and cleanup.
#
# Related files:
#   - lib/assistant/auth/magic_link.ex (module under test)
#   - lib/assistant/schemas/auth_token.ex (schema)

defmodule Assistant.Auth.MagicLinkTest do
  use Assistant.DataCase, async: true

  alias Assistant.Auth.MagicLink
  alias Assistant.Schemas.AuthToken

  # ---------------------------------------------------------------
  # Setup — create a test user + helper to insert auth_tokens
  # ---------------------------------------------------------------

  setup do
    user = insert_test_user()
    %{user: user}
  end

  defp insert_test_user do
    %Assistant.Schemas.User{}
    |> Assistant.Schemas.User.changeset(%{
      external_id: "magic-link-test-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Repo.insert!()
  end

  # Insert an auth_token record directly (bypasses generate/3 which needs OAuth)
  defp insert_auth_token(user_id, raw_token, opts \\ []) do
    token_hash = MagicLink.hash_token(raw_token)
    expires_at = Keyword.get(opts, :expires_at, future_expiry())
    used_at = Keyword.get(opts, :used_at, nil)

    %AuthToken{}
    |> AuthToken.changeset(%{
      user_id: user_id,
      token_hash: token_hash,
      purpose: "oauth_google",
      code_verifier: "test-verifier-#{System.unique_integer([:positive])}",
      pending_intent: %{"message" => "test command", "channel" => "test"},
      expires_at: expires_at,
      used_at: used_at
    })
    |> Repo.insert!()
  end

  defp future_expiry, do: DateTime.add(DateTime.utc_now(), 600, :second)
  defp past_expiry, do: DateTime.add(DateTime.utc_now(), -600, :second)

  # ---------------------------------------------------------------
  # hash_token
  # ---------------------------------------------------------------

  describe "hash_token/1" do
    test "produces consistent SHA-256 base64url hash" do
      hash1 = MagicLink.hash_token("my-token")
      hash2 = MagicLink.hash_token("my-token")
      assert hash1 == hash2
      # Base64url encoded, no padding
      refute String.contains?(hash1, "+")
      refute String.contains?(hash1, "/")
      refute String.ends_with?(hash1, "=")
    end

    test "different tokens produce different hashes" do
      refute MagicLink.hash_token("token-a") == MagicLink.hash_token("token-b")
    end
  end

  # ---------------------------------------------------------------
  # validate
  # ---------------------------------------------------------------

  describe "validate/1" do
    test "returns :not_found for unknown token" do
      assert {:error, :not_found} = MagicLink.validate("nonexistent-token")
    end

    test "returns {:ok, auth_token} for valid unexpired unused token", %{user: user} do
      raw_token = "valid-test-token-#{System.unique_integer([:positive])}"
      insert_auth_token(user.id, raw_token)

      assert {:ok, %AuthToken{} = auth_token} = MagicLink.validate(raw_token)
      assert auth_token.user_id == user.id
      assert auth_token.purpose == "oauth_google"
    end

    test "returns :already_used for consumed token", %{user: user} do
      raw_token = "used-token-#{System.unique_integer([:positive])}"
      insert_auth_token(user.id, raw_token, used_at: DateTime.utc_now())

      assert {:error, :already_used} = MagicLink.validate(raw_token)
    end

    test "returns :expired for expired token", %{user: user} do
      raw_token = "expired-token-#{System.unique_integer([:positive])}"
      insert_auth_token(user.id, raw_token, expires_at: past_expiry())

      assert {:error, :expired} = MagicLink.validate(raw_token)
    end
  end

  # ---------------------------------------------------------------
  # consume
  # ---------------------------------------------------------------

  describe "consume/1" do
    test "returns :not_found for unknown token" do
      assert {:error, :not_found} = MagicLink.consume("nonexistent-consume-token")
    end

    test "atomically consumes a valid token", %{user: user} do
      raw_token = "consume-test-#{System.unique_integer([:positive])}"
      insert_auth_token(user.id, raw_token)

      assert {:ok, %AuthToken{} = auth_token} = MagicLink.consume(raw_token)
      assert auth_token.user_id == user.id
      assert not is_nil(auth_token.used_at)
    end

    test "returns :already_used on second consume", %{user: user} do
      raw_token = "double-consume-#{System.unique_integer([:positive])}"
      insert_auth_token(user.id, raw_token)

      assert {:ok, _} = MagicLink.consume(raw_token)
      assert {:error, :already_used} = MagicLink.consume(raw_token)
    end

    test "returns :already_used for pre-consumed token", %{user: user} do
      raw_token = "pre-consumed-#{System.unique_integer([:positive])}"
      insert_auth_token(user.id, raw_token, used_at: DateTime.utc_now())

      assert {:error, :already_used} = MagicLink.consume(raw_token)
    end

    test "returns :expired for expired token", %{user: user} do
      raw_token = "expired-consume-#{System.unique_integer([:positive])}"
      insert_auth_token(user.id, raw_token, expires_at: past_expiry())

      assert {:error, :expired} = MagicLink.consume(raw_token)
    end

    test "consumed token includes code_verifier and pending_intent", %{user: user} do
      raw_token = "fields-check-#{System.unique_integer([:positive])}"
      insert_auth_token(user.id, raw_token)

      assert {:ok, auth_token} = MagicLink.consume(raw_token)
      assert is_binary(auth_token.code_verifier)
      assert is_map(auth_token.pending_intent)
      assert auth_token.pending_intent["message"] == "test command"
    end
  end

  # ---------------------------------------------------------------
  # cleanup_expired
  # ---------------------------------------------------------------

  describe "cleanup_expired/0" do
    test "deletes tokens expired more than 24 hours ago", %{user: user} do
      # Token expired 25 hours ago
      old_expiry = DateTime.add(DateTime.utc_now(), -25 * 3600, :second)
      raw_token = "old-expired-#{System.unique_integer([:positive])}"
      insert_auth_token(user.id, raw_token, expires_at: old_expiry)

      count = MagicLink.cleanup_expired()
      assert count >= 1

      # Verify it's gone
      assert {:error, :not_found} = MagicLink.validate(raw_token)
    end

    test "does not delete recently expired tokens", %{user: user} do
      # Token expired 1 hour ago (within 24-hour retention)
      recent_expiry = DateTime.add(DateTime.utc_now(), -3600, :second)
      raw_token = "recent-expired-#{System.unique_integer([:positive])}"
      insert_auth_token(user.id, raw_token, expires_at: recent_expiry)

      _count = MagicLink.cleanup_expired()

      # Should still be findable (just expired, not cleaned up)
      assert {:error, :expired} = MagicLink.validate(raw_token)
    end

    test "does not delete valid unexpired tokens", %{user: user} do
      raw_token = "still-valid-#{System.unique_integer([:positive])}"
      insert_auth_token(user.id, raw_token)

      MagicLink.cleanup_expired()

      assert {:ok, _} = MagicLink.validate(raw_token)
    end
  end
end

# test/assistant/auth/magic_link_generate_test.exs
#
# Tests for MagicLink.generate/3 — the full generation flow including
# rate limiting, token uniqueness, and invalidation of prior tokens.
# Requires OAuth client_id to be configured.
#
# Related files:
#   - lib/assistant/auth/magic_link.ex (module under test)
#   - lib/assistant/auth/oauth.ex (authorize_url builder)

defmodule Assistant.Auth.MagicLinkGenerateTest do
  # async: false — this test modifies global Application env
  # (google_oauth_client_id/secret) which races with other async tests.
  use Assistant.DataCase, async: false

  alias Assistant.Auth.MagicLink
  alias Assistant.Schemas.AuthToken

  # ---------------------------------------------------------------
  # Setup — create test user + configure OAuth credentials
  # ---------------------------------------------------------------

  setup do
    user = insert_test_user()

    Application.put_env(:assistant, :google_oauth_client_id, "test-client-id")
    Application.put_env(:assistant, :google_oauth_client_secret, "test-client-secret")

    on_exit(fn ->
      Application.delete_env(:assistant, :google_oauth_client_id)
      Application.delete_env(:assistant, :google_oauth_client_secret)
    end)

    %{user: user}
  end

  defp insert_test_user do
    %Assistant.Schemas.User{}
    |> Assistant.Schemas.User.changeset(%{
      external_id: "ml-gen-test-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Repo.insert!()
  end

  # ---------------------------------------------------------------
  # generate/3 — happy path
  # ---------------------------------------------------------------

  describe "generate/3" do
    test "returns token, URL, and auth_token_id", %{user: user} do
      pending_intent = %{"message" => "search drive", "channel" => "google_chat"}

      assert {:ok, result} = MagicLink.generate(user.id, "google_chat", pending_intent)

      assert is_binary(result.token)
      assert byte_size(result.token) > 20
      assert result.url =~ "accounts.google.com"
      assert result.url =~ "client_id=test-client-id"
      assert is_binary(result.auth_token_id)
    end

    test "token is consumable after generation", %{user: user} do
      pending_intent = %{"message" => "test cmd", "channel" => "test"}
      {:ok, result} = MagicLink.generate(user.id, "test", pending_intent)

      assert {:ok, %AuthToken{} = consumed} = MagicLink.consume(result.token)
      assert consumed.user_id == user.id
      assert consumed.pending_intent["message"] == "test cmd"
      assert is_binary(consumed.code_verifier)
    end

    test "generated tokens are unique", %{user: user} do
      intent = %{"message" => "cmd", "channel" => "test"}

      # First generation — this will invalidate any prior tokens
      {:ok, r1} = MagicLink.generate(user.id, "test", intent)
      # Second generation — invalidates the first
      {:ok, r2} = MagicLink.generate(user.id, "test", intent)

      assert r1.token != r2.token
      assert r1.auth_token_id != r2.auth_token_id
    end

    test "invalidates prior unused tokens on generation", %{user: user} do
      intent = %{"message" => "cmd", "channel" => "test"}
      {:ok, first} = MagicLink.generate(user.id, "test", intent)
      {:ok, _second} = MagicLink.generate(user.id, "test", intent)

      # First token should be invalidated (consumed by invalidation)
      assert {:error, :already_used} = MagicLink.consume(first.token)
    end

    test "stores PKCE code_verifier in auth_token", %{user: user} do
      intent = %{"message" => "cmd", "channel" => "test"}
      {:ok, result} = MagicLink.generate(user.id, "test", intent)

      auth_token = Repo.get!(AuthToken, result.auth_token_id)
      assert is_binary(auth_token.code_verifier)
      assert byte_size(auth_token.code_verifier) > 40
    end

    test "stores pending_intent encrypted in auth_token", %{user: user} do
      intent = %{
        "message" => "search my drive",
        "channel" => "google_chat",
        "conversation_id" => "conv-123"
      }

      {:ok, result} = MagicLink.generate(user.id, "google_chat", intent)

      auth_token = Repo.get!(AuthToken, result.auth_token_id)
      assert auth_token.pending_intent["message"] == "search my drive"
      assert auth_token.pending_intent["conversation_id"] == "conv-123"
    end

    test "returns error when client_id not configured", %{user: user} do
      Application.delete_env(:assistant, :google_oauth_client_id)
      intent = %{"message" => "cmd", "channel" => "test"}

      assert {:error, :missing_google_oauth_client_id} =
               MagicLink.generate(user.id, "test", intent)
    end
  end

  # ---------------------------------------------------------------
  # generate/3 — rate limiting
  # ---------------------------------------------------------------

  describe "generate/3 rate limiting" do
    test "allows up to 3 active magic links before rate limiting", %{user: user} do
      # Note: generate/3 invalidates existing tokens before inserting.
      # The rate limit checks BEFORE invalidation, counting active tokens.
      # Since invalidation runs before insert, and rate limit checks first,
      # in practice we should be able to generate one at a time since
      # invalidation clears previous ones.

      intent = %{"message" => "cmd1", "channel" => "test"}

      # These should succeed because each call invalidates prior ones
      assert {:ok, _} = MagicLink.generate(user.id, "test", intent)
      assert {:ok, _} = MagicLink.generate(user.id, "test", intent)
      assert {:ok, _} = MagicLink.generate(user.id, "test", intent)
    end

    test "rate limits when too many active tokens exist via direct insertion", %{user: user} do
      # Bypass generate/3 to insert 3 active tokens directly
      # (simulating a scenario where invalidation didn't clear them)
      for i <- 1..3 do
        token_hash = MagicLink.hash_token("rate-limit-token-#{i}")

        %AuthToken{}
        |> AuthToken.changeset(%{
          user_id: user.id,
          token_hash: token_hash,
          purpose: "oauth_google",
          code_verifier: "verifier-#{i}",
          pending_intent: %{"message" => "cmd"},
          expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
        })
        |> Repo.insert!()
      end

      intent = %{"message" => "should-fail", "channel" => "test"}
      assert {:error, :rate_limited} = MagicLink.generate(user.id, "test", intent)
    end
  end
end

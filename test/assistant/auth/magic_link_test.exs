# test/assistant/auth/magic_link_test.exs — MagicLink generate/validate/consume lifecycle tests.
#
# Risk Tier: CRITICAL — Magic links gate the OAuth2 flow. Single-use atomicity,
# expiry enforcement, and latest-wins invalidation are security-critical.

defmodule Assistant.Auth.MagicLinkTest do
  use Assistant.DataCase, async: false

  alias Assistant.Auth.MagicLink
  alias Assistant.Schemas.AuthToken
  alias Assistant.Schemas.User

  # -------------------------------------------------------------------
  # Setup — create a test user for FK constraints
  # -------------------------------------------------------------------

  setup do
    {:ok, user} =
      Repo.insert(
        User.changeset(%User{}, %{
          external_id: "ml-test-user-#{System.unique_integer([:positive])}",
          channel: "test"
        })
      )

    # Ensure endpoint host is set for URL building
    original_config = Application.get_env(:assistant, AssistantWeb.Endpoint, [])

    merged =
      Keyword.update(original_config, :url, [host: "test.example.com"], fn url_opts ->
        Keyword.put(url_opts, :host, "test.example.com")
      end)

    Application.put_env(:assistant, AssistantWeb.Endpoint, merged)

    on_exit(fn ->
      Application.put_env(:assistant, AssistantWeb.Endpoint, original_config)
    end)

    %{user: user}
  end

  # -------------------------------------------------------------------
  # generate/2
  # -------------------------------------------------------------------

  describe "generate/2" do
    test "returns a token, hash, and URL on success", %{user: user} do
      assert {:ok, %{token: token, token_hash: hash, url: url}} =
               MagicLink.generate(user.id)

      assert is_binary(token)
      assert byte_size(token) > 0
      assert String.match?(hash, ~r/^[0-9a-f]{64}$/)
      assert url =~ "https://test.example.com/auth/google/start?token="
      assert url =~ token
    end

    test "stores a hashed token in the database", %{user: user} do
      {:ok, %{token: raw_token, token_hash: expected_hash}} = MagicLink.generate(user.id)

      auth_token = Repo.one!(from(t in AuthToken, where: t.token_hash == ^expected_hash))
      assert auth_token.user_id == user.id
      assert auth_token.purpose == "oauth_google"
      assert is_nil(auth_token.used_at)

      computed_hash = :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
      assert auth_token.token_hash == computed_hash
    end

    test "sets default purpose to 'oauth_google'", %{user: user} do
      {:ok, %{token_hash: hash}} = MagicLink.generate(user.id)
      auth_token = Repo.one!(from(t in AuthToken, where: t.token_hash == ^hash))
      assert auth_token.purpose == "oauth_google"
    end

    test "stores oban_job_id when set on auth_token", %{user: user} do
      # Generate a token without pending_intent (Oban inline mode cannot safely
      # execute PendingIntentWorker inside MagicLink's Repo.transaction in tests).
      # Then verify the oban_job_id field is stored and retrievable when set.
      {:ok, %{token_hash: hash}} = MagicLink.generate(user.id)

      auth_token = Repo.one!(from(t in AuthToken, where: t.token_hash == ^hash))
      assert is_nil(auth_token.oban_job_id)

      # Simulate what MagicLink.generate does when pending_intent is provided:
      # it inserts an Oban job and stores the ID on the auth_token row.
      auth_token
      |> Ecto.Changeset.change(oban_job_id: 42)
      |> Repo.update!()

      updated = Repo.one!(from(t in AuthToken, where: t.token_hash == ^hash))
      assert updated.oban_job_id == 42
    end

    test "sets expires_at to ~10 minutes in the future", %{user: user} do
      {:ok, %{token_hash: hash}} = MagicLink.generate(user.id)
      auth_token = Repo.one!(from(t in AuthToken, where: t.token_hash == ^hash))

      diff = DateTime.diff(auth_token.expires_at, DateTime.utc_now())
      assert diff >= 9 * 60
      assert diff <= 11 * 60
    end

    test "latest-wins: new token invalidates pending ones for same user", %{user: user} do
      {:ok, %{token: token1, token_hash: hash1}} = MagicLink.generate(user.id)
      {:ok, %{token: _token2, token_hash: hash2}} = MagicLink.generate(user.id)

      old_token = Repo.one!(from(t in AuthToken, where: t.token_hash == ^hash1))
      assert not is_nil(old_token.used_at), "First token should be invalidated"

      new_token = Repo.one!(from(t in AuthToken, where: t.token_hash == ^hash2))
      assert is_nil(new_token.used_at), "Second token should still be active"

      assert {:error, :already_used} = MagicLink.validate(token1)
    end

    test "generates unique tokens on successive calls", %{user: user} do
      {:ok, %{token: t1}} = MagicLink.generate(user.id)
      {:ok, %{token: t2}} = MagicLink.generate(user.id)
      refute t1 == t2
    end

    test "latest-wins does NOT invalidate tokens for different users", %{user: user} do
      {:ok, user2} =
        Repo.insert(
          User.changeset(%User{}, %{
            external_id: "ml-test-user2-#{System.unique_integer([:positive])}",
            channel: "test"
          })
        )

      {:ok, %{token: token1}} = MagicLink.generate(user.id)
      {:ok, _} = MagicLink.generate(user2.id)

      # user1's token should still validate
      assert {:ok, %{user_id: uid}} = MagicLink.validate(token1)
      assert uid == user.id
    end
  end

  # -------------------------------------------------------------------
  # validate/1
  # -------------------------------------------------------------------

  describe "validate/1" do
    test "returns user_id and oban_job_id for a valid token", %{user: user} do
      {:ok, %{token: raw_token, token_hash: hash}} = MagicLink.generate(user.id)

      # Simulate oban_job_id being set (as MagicLink.generate does with pending_intent)
      from(t in AuthToken, where: t.token_hash == ^hash)
      |> Repo.update_all(set: [oban_job_id: 99])

      assert {:ok, %{user_id: uid, oban_job_id: 99}} = MagicLink.validate(raw_token)
      assert uid == user.id
    end

    test "returns {:error, :not_found} for a non-existent token" do
      assert {:error, :not_found} = MagicLink.validate("totally-bogus-token")
    end

    test "returns {:error, :already_used} for a consumed token", %{user: user} do
      {:ok, %{token: raw_token}} = MagicLink.generate(user.id)
      {:ok, _} = MagicLink.consume(raw_token)

      assert {:error, :already_used} = MagicLink.validate(raw_token)
    end

    test "returns {:error, :expired} for an expired token", %{user: user} do
      {:ok, %{token: raw_token, token_hash: hash}} = MagicLink.generate(user.id)

      from(t in AuthToken, where: t.token_hash == ^hash)
      |> Repo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)])

      assert {:error, :expired} = MagicLink.validate(raw_token)
    end

    test "returns oban_job_id as nil when not set", %{user: user} do
      {:ok, %{token: raw_token}} = MagicLink.generate(user.id)

      assert {:ok, %{user_id: _, oban_job_id: nil}} = MagicLink.validate(raw_token)
    end
  end

  # -------------------------------------------------------------------
  # consume/1
  # -------------------------------------------------------------------

  describe "consume/1" do
    test "marks the token as used and returns the auth_token", %{user: user} do
      {:ok, %{token: raw_token, token_hash: hash}} = MagicLink.generate(user.id)

      # Simulate oban_job_id being set (as MagicLink.generate does with pending_intent)
      from(t in AuthToken, where: t.token_hash == ^hash)
      |> Repo.update_all(set: [oban_job_id: 7])

      assert {:ok, %AuthToken{} = auth_token} = MagicLink.consume(raw_token)
      assert auth_token.user_id == user.id
      assert auth_token.oban_job_id == 7
      assert not is_nil(auth_token.used_at)
    end

    test "is single-use — second consume returns :already_used", %{user: user} do
      {:ok, %{token: raw_token}} = MagicLink.generate(user.id)

      assert {:ok, _} = MagicLink.consume(raw_token)
      assert {:error, :already_used} = MagicLink.consume(raw_token)
    end

    test "returns {:error, :not_found} for unknown token" do
      assert {:error, :not_found} = MagicLink.consume("nonexistent-token")
    end

    test "returns {:error, :expired} for an expired token", %{user: user} do
      {:ok, %{token: raw_token, token_hash: hash}} = MagicLink.generate(user.id)

      from(t in AuthToken, where: t.token_hash == ^hash)
      |> Repo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)])

      assert {:error, :expired} = MagicLink.consume(raw_token)
    end

    test "atomic single-use: concurrent consume calls, only one succeeds", %{user: user} do
      {:ok, %{token: raw_token}} = MagicLink.generate(user.id)

      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            MagicLink.consume(raw_token)
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      successes = Enum.count(results, &match?({:ok, _}, &1))

      assert successes == 1, "Expected exactly 1 success, got #{successes}"
    end
  end

  # -------------------------------------------------------------------
  # Token hashing security
  # -------------------------------------------------------------------

  describe "token hashing security" do
    test "raw token is never stored in the database", %{user: user} do
      {:ok, %{token: raw_token}} = MagicLink.generate(user.id)

      all_tokens = Repo.all(from(t in AuthToken, where: t.user_id == ^user.id))

      for token <- all_tokens do
        refute token.token_hash == raw_token,
               "Raw token was stored directly in the database"
      end
    end
  end
end

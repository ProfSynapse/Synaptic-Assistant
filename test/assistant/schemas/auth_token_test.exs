# test/assistant/schemas/auth_token_test.exs
#
# Changeset tests for the AuthToken schema (magic link tokens).
# Verifies required fields, validation rules, purpose inclusion,
# and unique constraint on token_hash.
#
# Related files:
#   - lib/assistant/schemas/auth_token.ex (module under test)
#   - lib/assistant/auth/magic_link.ex (context module)

defmodule Assistant.Schemas.AuthTokenTest do
  use Assistant.DataCase, async: true

  alias Assistant.Schemas.AuthToken

  # ---------------------------------------------------------------
  # Setup — test user for FK constraint
  # ---------------------------------------------------------------

  setup do
    user = insert_test_user()
    %{user: user}
  end

  defp insert_test_user do
    %Assistant.Schemas.User{}
    |> Assistant.Schemas.User.changeset(%{
      external_id: "auth-token-schema-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Repo.insert!()
  end

  defp valid_attrs(user) do
    %{
      user_id: user.id,
      token_hash: "hash-#{System.unique_integer([:positive])}",
      purpose: "oauth_google",
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
    }
  end

  # ---------------------------------------------------------------
  # Valid changeset
  # ---------------------------------------------------------------

  describe "changeset/2 — valid" do
    test "accepts all required fields", %{user: user} do
      changeset = AuthToken.changeset(%AuthToken{}, valid_attrs(user))
      assert changeset.valid?
    end

    test "accepts required + optional fields", %{user: user} do
      attrs =
        valid_attrs(user)
        |> Map.merge(%{
          code_verifier: "pkce-verifier-string",
          oban_job_id: 42,
          pending_intent: %{"message" => "search my drive", "channel" => "google_chat"},
          used_at: DateTime.utc_now()
        })

      changeset = AuthToken.changeset(%AuthToken{}, attrs)
      assert changeset.valid?
    end
  end

  # ---------------------------------------------------------------
  # Invalid changeset — missing required fields
  # ---------------------------------------------------------------

  describe "changeset/2 — missing required fields" do
    test "rejects missing user_id" do
      attrs = %{token_hash: "hash", purpose: "oauth_google", expires_at: DateTime.utc_now()}
      changeset = AuthToken.changeset(%AuthToken{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).user_id
    end

    test "rejects missing token_hash", %{user: user} do
      attrs = %{user_id: user.id, purpose: "oauth_google", expires_at: DateTime.utc_now()}
      changeset = AuthToken.changeset(%AuthToken{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).token_hash
    end

    test "rejects missing purpose", %{user: user} do
      attrs = %{user_id: user.id, token_hash: "hash", expires_at: DateTime.utc_now()}
      changeset = AuthToken.changeset(%AuthToken{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).purpose
    end

    test "rejects missing expires_at", %{user: user} do
      attrs = %{user_id: user.id, token_hash: "hash", purpose: "oauth_google"}
      changeset = AuthToken.changeset(%AuthToken{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).expires_at
    end

    test "rejects empty attrs" do
      changeset = AuthToken.changeset(%AuthToken{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors.user_id
      assert "can't be blank" in errors.token_hash
      assert "can't be blank" in errors.purpose
      assert "can't be blank" in errors.expires_at
    end
  end

  # ---------------------------------------------------------------
  # Purpose validation
  # ---------------------------------------------------------------

  describe "changeset/2 — purpose validation" do
    test "rejects invalid purpose", %{user: user} do
      attrs = %{valid_attrs(user) | purpose: "invalid_purpose"}
      changeset = AuthToken.changeset(%AuthToken{}, attrs)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).purpose
    end

    test "accepts oauth_google purpose", %{user: user} do
      changeset = AuthToken.changeset(%AuthToken{}, valid_attrs(user))
      assert changeset.valid?
    end
  end

  # ---------------------------------------------------------------
  # token_hash uniqueness
  # ---------------------------------------------------------------

  describe "unique constraint on token_hash" do
    test "prevents duplicate token_hash", %{user: user} do
      shared_hash = "unique-hash-#{System.unique_integer([:positive])}"

      attrs1 = %{valid_attrs(user) | token_hash: shared_hash}

      {:ok, _} =
        %AuthToken{}
        |> AuthToken.changeset(attrs1)
        |> Repo.insert()

      # Second insert with same token_hash should fail
      attrs2 = %{valid_attrs(user) | token_hash: shared_hash}

      {:error, changeset} =
        %AuthToken{}
        |> AuthToken.changeset(attrs2)
        |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).token_hash
    end

    test "allows different token_hashes for same user", %{user: user} do
      {:ok, _} =
        %AuthToken{}
        |> AuthToken.changeset(valid_attrs(user))
        |> Repo.insert()

      {:ok, _} =
        %AuthToken{}
        |> AuthToken.changeset(valid_attrs(user))
        |> Repo.insert()
    end
  end
end

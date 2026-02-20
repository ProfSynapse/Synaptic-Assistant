# test/assistant/schemas/oauth_token_test.exs
#
# Changeset tests for the OAuthToken schema.
# Verifies required fields, validation rules, encryption roundtrip,
# and unique constraint on [user_id, provider].
#
# Related files:
#   - lib/assistant/schemas/oauth_token.ex (module under test)
#   - lib/assistant/auth/token_store.ex (context module)

defmodule Assistant.Schemas.OAuthTokenTest do
  use Assistant.DataCase, async: true

  alias Assistant.Schemas.OAuthToken

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
      external_id: "oauth-token-schema-#{System.unique_integer([:positive])}",
      channel: "test"
    })
    |> Repo.insert!()
  end

  # ---------------------------------------------------------------
  # Valid changeset
  # ---------------------------------------------------------------

  describe "changeset/2 — valid" do
    test "accepts all required fields", %{user: user} do
      attrs = %{
        user_id: user.id,
        provider: "google",
        refresh_token: "1//refresh-token"
      }

      changeset = OAuthToken.changeset(%OAuthToken{}, attrs)
      assert changeset.valid?
    end

    test "accepts required + optional fields", %{user: user} do
      attrs = %{
        user_id: user.id,
        provider: "google",
        refresh_token: "1//refresh-token",
        access_token: "ya29.access-token",
        token_expires_at: DateTime.utc_now(),
        provider_email: "user@example.com",
        provider_uid: "google-uid-123",
        scopes: "openid email profile"
      }

      changeset = OAuthToken.changeset(%OAuthToken{}, attrs)
      assert changeset.valid?
    end
  end

  # ---------------------------------------------------------------
  # Invalid changeset — missing required fields
  # ---------------------------------------------------------------

  describe "changeset/2 — missing required fields" do
    test "rejects missing user_id" do
      attrs = %{provider: "google", refresh_token: "rt"}
      changeset = OAuthToken.changeset(%OAuthToken{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).user_id
    end

    test "rejects missing provider" do
      attrs = %{user_id: Ecto.UUID.generate(), refresh_token: "rt"}
      changeset = OAuthToken.changeset(%OAuthToken{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).provider
    end

    test "rejects missing refresh_token" do
      attrs = %{user_id: Ecto.UUID.generate(), provider: "google"}
      changeset = OAuthToken.changeset(%OAuthToken{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).refresh_token
    end

    test "rejects empty attrs" do
      changeset = OAuthToken.changeset(%OAuthToken{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors.user_id
      assert "can't be blank" in errors.provider
      assert "can't be blank" in errors.refresh_token
    end
  end

  # ---------------------------------------------------------------
  # Provider validation
  # ---------------------------------------------------------------

  describe "changeset/2 — provider validation" do
    test "rejects invalid provider", %{user: user} do
      attrs = %{user_id: user.id, provider: "facebook", refresh_token: "rt"}
      changeset = OAuthToken.changeset(%OAuthToken{}, attrs)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).provider
    end

    test "accepts google provider", %{user: user} do
      attrs = %{user_id: user.id, provider: "google", refresh_token: "rt"}
      changeset = OAuthToken.changeset(%OAuthToken{}, attrs)
      assert changeset.valid?
    end
  end

  # ---------------------------------------------------------------
  # Encrypted fields roundtrip
  # ---------------------------------------------------------------

  describe "encrypted fields" do
    test "access_token and refresh_token are encrypted at rest", %{user: user} do
      {:ok, _token} =
        %OAuthToken{}
        |> OAuthToken.changeset(%{
          user_id: user.id,
          provider: "google",
          refresh_token: "plaintext-refresh",
          access_token: "plaintext-access"
        })
        |> Repo.insert()

      # Read via schema (decrypted)
      token = Repo.one(from t in OAuthToken, where: t.user_id == ^user.id)
      assert token.refresh_token == "plaintext-refresh"
      assert token.access_token == "plaintext-access"

      # Read raw from DB (encrypted — should differ from plaintext)
      raw =
        Repo.one(
          from t in "oauth_tokens",
            where: t.user_id == type(^user.id, :binary_id),
            select: %{refresh_token: t.refresh_token, access_token: t.access_token}
        )

      assert raw.refresh_token != "plaintext-refresh"
      assert raw.access_token != "plaintext-access"
    end
  end

  # ---------------------------------------------------------------
  # Unique constraint
  # ---------------------------------------------------------------

  describe "unique constraint [user_id, provider]" do
    test "prevents duplicate user_id + provider", %{user: user} do
      attrs = %{user_id: user.id, provider: "google", refresh_token: "rt-1"}

      {:ok, _} =
        %OAuthToken{}
        |> OAuthToken.changeset(attrs)
        |> Repo.insert()

      {:error, changeset} =
        %OAuthToken{}
        |> OAuthToken.changeset(%{attrs | refresh_token: "rt-2"})
        |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).user_id
    end
  end
end

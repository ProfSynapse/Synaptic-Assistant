# test/assistant/schemas/oauth_token_test.exs — OAuthToken changeset tests.
#
# Risk Tier: STANDARD — Schema validation for encrypted OAuth tokens.

defmodule Assistant.Schemas.OAuthTokenTest do
  use ExUnit.Case, async: true

  alias Assistant.Schemas.OAuthToken

  # -------------------------------------------------------------------
  # changeset/2
  # -------------------------------------------------------------------

  describe "changeset/2" do
    test "valid changeset with required fields" do
      attrs = %{
        user_id: Ecto.UUID.generate(),
        provider: "google",
        refresh_token: "refresh-tok"
      }

      changeset = OAuthToken.changeset(%OAuthToken{}, attrs)
      assert changeset.valid?
    end

    test "invalid without user_id" do
      attrs = %{provider: "google", refresh_token: "tok"}
      changeset = OAuthToken.changeset(%OAuthToken{}, attrs)
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :user_id)
    end

    test "invalid without provider" do
      attrs = %{user_id: Ecto.UUID.generate(), refresh_token: "tok"}
      changeset = OAuthToken.changeset(%OAuthToken{}, attrs)
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :provider)
    end

    test "invalid without refresh_token" do
      attrs = %{user_id: Ecto.UUID.generate(), provider: "google"}
      changeset = OAuthToken.changeset(%OAuthToken{}, attrs)
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :refresh_token)
    end

    test "invalid with unknown provider" do
      attrs = %{
        user_id: Ecto.UUID.generate(),
        provider: "github",
        refresh_token: "tok"
      }

      changeset = OAuthToken.changeset(%OAuthToken{}, attrs)
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :provider)
    end

    test "accepts optional fields" do
      attrs = %{
        user_id: Ecto.UUID.generate(),
        provider: "google",
        refresh_token: "tok",
        provider_uid: "sub-123",
        provider_email: "user@gmail.com",
        access_token: "access-tok",
        token_expires_at: DateTime.utc_now(),
        scopes: "openid email"
      }

      changeset = OAuthToken.changeset(%OAuthToken{}, attrs)
      assert changeset.valid?
    end
  end

  # -------------------------------------------------------------------
  # refresh_changeset/2
  # -------------------------------------------------------------------

  describe "refresh_changeset/2" do
    test "valid with access_token" do
      existing = %OAuthToken{
        user_id: Ecto.UUID.generate(),
        provider: "google",
        refresh_token: "orig"
      }

      changeset =
        OAuthToken.refresh_changeset(existing, %{
          access_token: "new-access",
          token_expires_at: DateTime.utc_now()
        })

      assert changeset.valid?
    end

    test "invalid without access_token" do
      existing = %OAuthToken{
        user_id: Ecto.UUID.generate(),
        provider: "google",
        refresh_token: "orig"
      }

      changeset = OAuthToken.refresh_changeset(existing, %{})
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :access_token)
    end
  end
end

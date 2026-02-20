# test/assistant/schemas/auth_token_test.exs — AuthToken changeset and helper tests.
#
# Risk Tier: STANDARD — Schema validation for magic link tokens.

defmodule Assistant.Schemas.AuthTokenTest do
  use ExUnit.Case, async: true

  alias Assistant.Schemas.AuthToken

  # -------------------------------------------------------------------
  # changeset/2
  # -------------------------------------------------------------------

  describe "changeset/2" do
    test "valid changeset with all required fields" do
      attrs = %{
        user_id: Ecto.UUID.generate(),
        token_hash: "abc123def456",
        purpose: "oauth_google",
        expires_at: DateTime.utc_now()
      }

      changeset = AuthToken.changeset(%AuthToken{}, attrs)
      assert changeset.valid?
    end

    test "invalid without user_id" do
      attrs = %{
        token_hash: "abc",
        purpose: "oauth_google",
        expires_at: DateTime.utc_now()
      }

      changeset = AuthToken.changeset(%AuthToken{}, attrs)
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :user_id)
    end

    test "invalid without token_hash" do
      attrs = %{
        user_id: Ecto.UUID.generate(),
        purpose: "oauth_google",
        expires_at: DateTime.utc_now()
      }

      changeset = AuthToken.changeset(%AuthToken{}, attrs)
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :token_hash)
    end

    test "invalid without purpose" do
      attrs = %{
        user_id: Ecto.UUID.generate(),
        token_hash: "abc",
        expires_at: DateTime.utc_now()
      }

      changeset = AuthToken.changeset(%AuthToken{}, attrs)
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :purpose)
    end

    test "invalid without expires_at" do
      attrs = %{
        user_id: Ecto.UUID.generate(),
        token_hash: "abc",
        purpose: "oauth_google"
      }

      changeset = AuthToken.changeset(%AuthToken{}, attrs)
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :expires_at)
    end

    test "invalid with unknown purpose" do
      attrs = %{
        user_id: Ecto.UUID.generate(),
        token_hash: "abc",
        purpose: "password_reset",
        expires_at: DateTime.utc_now()
      }

      changeset = AuthToken.changeset(%AuthToken{}, attrs)
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :purpose)
    end

    test "accepts optional oban_job_id" do
      attrs = %{
        user_id: Ecto.UUID.generate(),
        token_hash: "abc",
        purpose: "oauth_google",
        expires_at: DateTime.utc_now(),
        oban_job_id: 42
      }

      changeset = AuthToken.changeset(%AuthToken{}, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :oban_job_id) == 42
    end
  end

  # -------------------------------------------------------------------
  # expired?/1
  # -------------------------------------------------------------------

  describe "expired?/1" do
    test "returns true for past expires_at" do
      token = %AuthToken{expires_at: DateTime.add(DateTime.utc_now(), -60, :second)}
      assert AuthToken.expired?(token)
    end

    test "returns false for future expires_at" do
      token = %AuthToken{expires_at: DateTime.add(DateTime.utc_now(), 60, :second)}
      refute AuthToken.expired?(token)
    end
  end

  # -------------------------------------------------------------------
  # used?/1
  # -------------------------------------------------------------------

  describe "used?/1" do
    test "returns true when used_at is set" do
      token = %AuthToken{used_at: DateTime.utc_now()}
      assert AuthToken.used?(token)
    end

    test "returns false when used_at is nil" do
      token = %AuthToken{used_at: nil}
      refute AuthToken.used?(token)
    end
  end
end

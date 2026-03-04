# test/assistant/schemas/user_identity_test.exs — Schema validation and
# constraint tests for UserIdentity.
#
# CRITICAL coverage target: 90%+ (data integrity).

defmodule Assistant.Schemas.UserIdentityTest do
  use Assistant.DataCase, async: true

  alias Assistant.Schemas.UserIdentity

  import Assistant.ChannelFixtures

  # Helper to create a user for FK tests
  defp create_user(attrs \\ %{}) do
    chat_user_fixture(attrs)
  end

  # ---------------------------------------------------------------
  # P0: changeset validation
  # ---------------------------------------------------------------

  describe "changeset/2 — required fields" do
    test "valid changeset with all required fields" do
      user = create_user()

      cs =
        UserIdentity.changeset(%UserIdentity{}, %{
          user_id: user.id,
          channel: "telegram",
          external_id: "123456789"
        })

      assert cs.valid?
    end

    test "invalid without channel" do
      user = create_user()

      cs =
        UserIdentity.changeset(%UserIdentity{}, %{
          user_id: user.id,
          external_id: "123456789"
        })

      refute cs.valid?
      assert errors_on(cs)[:channel] != nil
    end

    test "invalid without external_id" do
      user = create_user()

      cs =
        UserIdentity.changeset(%UserIdentity{}, %{
          user_id: user.id,
          channel: "telegram"
        })

      refute cs.valid?
      assert errors_on(cs)[:external_id] != nil
    end

    test "invalid without user_id" do
      cs =
        UserIdentity.changeset(%UserIdentity{}, %{
          channel: "telegram",
          external_id: "123456789"
        })

      refute cs.valid?
      assert errors_on(cs)[:user_id] != nil
    end
  end

  describe "changeset/2 — optional fields" do
    test "accepts space_id" do
      user = create_user()

      cs =
        UserIdentity.changeset(%UserIdentity{}, %{
          user_id: user.id,
          channel: "slack",
          external_id: "U0ABC",
          space_id: "T0WORKSPACE"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :space_id) == "T0WORKSPACE"
    end

    test "accepts display_name" do
      user = create_user()

      cs =
        UserIdentity.changeset(%UserIdentity{}, %{
          user_id: user.id,
          channel: "telegram",
          external_id: "123456789",
          display_name: "Test User"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :display_name) == "Test User"
    end

    test "accepts metadata map" do
      user = create_user()

      cs =
        UserIdentity.changeset(%UserIdentity{}, %{
          user_id: user.id,
          channel: "telegram",
          external_id: "123456789",
          metadata: %{"some_key" => "some_value"}
        })

      assert cs.valid?
    end
  end

  # ---------------------------------------------------------------
  # P0: unique constraint — (channel, external_id, space_id)
  # ---------------------------------------------------------------

  describe "unique constraint" do
    test "rejects duplicate (channel, external_id) with nil space_id" do
      user = create_user()

      {:ok, _} =
        %UserIdentity{}
        |> UserIdentity.changeset(%{
          user_id: user.id,
          channel: "telegram",
          external_id: "123456789"
        })
        |> Repo.insert()

      assert {:error, cs} =
               %UserIdentity{}
               |> UserIdentity.changeset(%{
                 user_id: user.id,
                 channel: "telegram",
                 external_id: "123456789"
               })
               |> Repo.insert()

      # The unique_constraint name maps to the composite key
      assert errors_on(cs)[:channel] != nil ||
               errors_on(cs)[:external_id] != nil ||
               Enum.any?(cs.errors, fn {_field, {_msg, opts}} ->
                 Keyword.get(opts, :constraint) == :unique
               end)
    end

    test "allows same external_id on different channels" do
      user = create_user()

      {:ok, _} =
        %UserIdentity{}
        |> UserIdentity.changeset(%{
          user_id: user.id,
          channel: "telegram",
          external_id: "123456789"
        })
        |> Repo.insert()

      assert {:ok, _} =
               %UserIdentity{}
               |> UserIdentity.changeset(%{
                 user_id: user.id,
                 channel: "discord",
                 external_id: "123456789"
               })
               |> Repo.insert()
    end

    test "allows same channel+external_id with different space_ids" do
      user = create_user()

      {:ok, _} =
        %UserIdentity{}
        |> UserIdentity.changeset(%{
          user_id: user.id,
          channel: "slack",
          external_id: "U0ABC",
          space_id: "T0WORKSPACE1"
        })
        |> Repo.insert()

      assert {:ok, _} =
               %UserIdentity{}
               |> UserIdentity.changeset(%{
                 user_id: user.id,
                 channel: "slack",
                 external_id: "U0ABC",
                 space_id: "T0WORKSPACE2"
               })
               |> Repo.insert()
    end
  end

  # ---------------------------------------------------------------
  # P0: foreign key constraint
  # ---------------------------------------------------------------

  describe "foreign key constraint" do
    test "rejects identity with non-existent user_id" do
      bogus_id = Ecto.UUID.generate()

      assert {:error, cs} =
               %UserIdentity{}
               |> UserIdentity.changeset(%{
                 user_id: bogus_id,
                 channel: "telegram",
                 external_id: "123456789"
               })
               |> Repo.insert()

      assert errors_on(cs)[:user_id] != nil
    end
  end

  # ---------------------------------------------------------------
  # P1: cascade delete
  # ---------------------------------------------------------------

  describe "cascade delete" do
    test "deleting a user deletes associated identities" do
      user = create_user()

      {:ok, identity} =
        %UserIdentity{}
        |> UserIdentity.changeset(%{
          user_id: user.id,
          channel: "telegram",
          external_id: "123456789"
        })
        |> Repo.insert()

      Repo.delete!(user)

      assert Repo.get(UserIdentity, identity.id) == nil
    end
  end

  # ---------------------------------------------------------------
  # P1: User association
  # ---------------------------------------------------------------

  describe "User.has_many :identities" do
    test "user has identities preloaded" do
      user = create_user()

      for i <- 1..3 do
        %UserIdentity{}
        |> UserIdentity.changeset(%{
          user_id: user.id,
          channel: "channel_#{i}",
          external_id: "ext_#{i}"
        })
        |> Repo.insert!()
      end

      user_with_identities = Repo.preload(user, :identities)
      assert length(user_with_identities.identities) == 3
    end
  end
end

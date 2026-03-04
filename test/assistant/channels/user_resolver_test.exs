# test/assistant/channels/user_resolver_test.exs — Tests for UserResolver.
#
# CRITICAL coverage target: 90%+ (identity data, security boundary).
# Tests platform identity resolution, user auto-creation, identity linking,
# race condition handling, and platform ID validation.

defmodule Assistant.Channels.UserResolverTest do
  use Assistant.DataCase, async: true

  alias Assistant.Channels.UserResolver
  alias Assistant.Schemas.{Conversation, User, UserIdentity}

  import Assistant.ChannelFixtures

  # ---------------------------------------------------------------
  # P0: resolve known user by (external_id, channel)
  # ---------------------------------------------------------------

  describe "resolve/3 — known user lookup" do
    test "returns user_id and conversation_id for existing identity" do
      {user, _identity, conversation} = user_with_conversation_fixture()

      assert {:ok, %{user_id: user_id, conversation_id: conv_id}} =
               UserResolver.resolve(:telegram, user.external_id)

      assert user_id == user.id
      assert conv_id == conversation.id
    end

    test "returns the same conversation on repeated calls" do
      {user, _identity, conversation} = user_with_conversation_fixture()

      {:ok, result1} = UserResolver.resolve(:telegram, user.external_id)
      {:ok, result2} = UserResolver.resolve(:telegram, user.external_id)

      assert result1.conversation_id == result2.conversation_id
      assert result1.conversation_id == conversation.id
    end

    test "different channels with same external_id are different users" do
      # User on telegram
      {user_tg, _id, _conv} =
        user_with_conversation_fixture(%{channel: "telegram", external_id: "123456789"})

      # User on discord (same numeric ID, different channel)
      {user_dc, _id, _conv} =
        user_with_conversation_fixture(%{channel: "discord", external_id: "123456789"})

      {:ok, result_tg} = UserResolver.resolve(:telegram, "123456789")
      {:ok, result_dc} = UserResolver.resolve(:discord, "123456789")

      assert result_tg.user_id == user_tg.id
      assert result_dc.user_id == user_dc.id
      refute result_tg.user_id == result_dc.user_id
    end
  end

  # ---------------------------------------------------------------
  # P0: create new user on first contact
  # ---------------------------------------------------------------

  describe "resolve/3 — auto-create new user" do
    test "creates user and identity on first contact" do
      external_id = "999888777"

      assert {:ok, %{user_id: user_id, conversation_id: conv_id}} =
               UserResolver.resolve(:telegram, external_id, %{display_name: "New User"})

      # Verify user was created
      user = Repo.get!(User, user_id)
      assert user.external_id == external_id
      assert user.channel == "telegram"

      # Verify identity was created
      identity =
        Repo.one!(
          from(ui in UserIdentity,
            where: ui.user_id == ^user_id and ui.channel == "telegram"
          )
        )

      assert identity.external_id == external_id
      assert identity.display_name == "New User"

      # Verify perpetual conversation was created
      conversation = Repo.get!(Conversation, conv_id)
      assert conversation.user_id == user_id
      assert conversation.channel == "unified"
      assert conversation.agent_type == "orchestrator"
      assert conversation.status == "active"
    end

    test "creates user with display_name from metadata" do
      {:ok, %{user_id: user_id}} =
        UserResolver.resolve(:telegram, "111222333", %{display_name: "Alice"})

      user = Repo.get!(User, user_id)
      assert user.display_name == "Alice"
    end

    test "creates user with space_id from metadata" do
      {:ok, %{user_id: user_id}} =
        UserResolver.resolve(:slack, "U0TESTSLACK", %{space_id: "T0WORKSPACE"})

      identity =
        Repo.one!(
          from(ui in UserIdentity,
            where: ui.user_id == ^user_id and ui.channel == "slack"
          )
        )

      assert identity.space_id == "T0WORKSPACE"
    end

    test "subsequent call after auto-create returns same user" do
      {:ok, result1} = UserResolver.resolve(:telegram, "444555666")
      {:ok, result2} = UserResolver.resolve(:telegram, "444555666")

      assert result1.user_id == result2.user_id
      assert result1.conversation_id == result2.conversation_id
    end

    test "links Google Chat identity to settings-linked user by email when available" do
      existing_user =
        chat_user_fixture(%{
          channel: "settings",
          external_id: "settings:gc-link-#{System.unique_integer([:positive])}"
        })

      {:ok, settings_user} =
        %Assistant.Accounts.SettingsUser{}
        |> Assistant.Accounts.SettingsUser.email_changeset(
          %{
            email: "gc-link-#{System.unique_integer([:positive])}@example.com"
          },
          validate_changed: false
        )
        |> Repo.insert()

      settings_user =
        settings_user
        |> Ecto.Changeset.change(%{user_id: existing_user.id})
        |> Repo.update!()

      external_id = "users/#{System.unique_integer([:positive])}"

      assert {:ok, %{user_id: resolved_user_id}} =
               UserResolver.resolve(:google_chat, external_id, %{
                 user_email: settings_user.email,
                 display_name: "GC User",
                 space_id: "spaces/AAAA"
               })

      assert resolved_user_id == existing_user.id

      identity =
        Repo.one!(
          from(ui in UserIdentity,
            where:
              ui.user_id == ^existing_user.id and
                ui.channel == "google_chat" and
                ui.external_id == ^external_id and
                ui.space_id == "spaces/AAAA"
          )
        )

      assert identity.display_name == "GC User"
    end

    test "re-links sole settings user from pseudo-user on first Google Chat resolve" do
      pseudo_user =
        chat_user_fixture(%{
          channel: "settings",
          external_id: "settings:gc-pseudo-#{System.unique_integer([:positive])}"
        })

      {:ok, settings_user} =
        %Assistant.Accounts.SettingsUser{}
        |> Assistant.Accounts.SettingsUser.email_changeset(
          %{email: "gc-pseudo-#{System.unique_integer([:positive])}@example.com"},
          validate_changed: false
        )
        |> Repo.insert()

      settings_user =
        settings_user
        |> Ecto.Changeset.change(%{user_id: pseudo_user.id})
        |> Repo.update!()

      external_id = "users/#{System.unique_integer([:positive])}"

      assert {:ok, %{user_id: resolved_user_id}} =
               UserResolver.resolve(:google_chat, external_id, %{display_name: "GC User"})

      refute resolved_user_id == pseudo_user.id

      reloaded_settings_user = Repo.get!(Assistant.Accounts.SettingsUser, settings_user.id)
      assert reloaded_settings_user.user_id == resolved_user_id
    end

    test "re-links sole settings user from pseudo-user when Google Chat identity already exists" do
      google_chat_user =
        chat_user_fixture(%{
          channel: "google_chat",
          external_id: "users/#{System.unique_integer([:positive])}"
        })

      _identity = user_identity_fixture(google_chat_user)

      pseudo_user =
        chat_user_fixture(%{
          channel: "settings",
          external_id: "settings:gc-existing-#{System.unique_integer([:positive])}"
        })

      {:ok, settings_user} =
        %Assistant.Accounts.SettingsUser{}
        |> Assistant.Accounts.SettingsUser.email_changeset(
          %{email: "gc-existing-#{System.unique_integer([:positive])}@example.com"},
          validate_changed: false
        )
        |> Repo.insert()

      settings_user =
        settings_user
        |> Ecto.Changeset.change(%{user_id: pseudo_user.id})
        |> Repo.update!()

      assert {:ok, %{user_id: resolved_user_id}} =
               UserResolver.resolve(:google_chat, google_chat_user.external_id)

      assert resolved_user_id == google_chat_user.id

      reloaded_settings_user = Repo.get!(Assistant.Accounts.SettingsUser, settings_user.id)
      assert reloaded_settings_user.user_id == google_chat_user.id
    end
  end

  # ---------------------------------------------------------------
  # P1: platform ID validation
  # ---------------------------------------------------------------

  describe "resolve/3 — platform ID validation" do
    test "rejects non-numeric Telegram ID" do
      assert {:error, :invalid_platform_id} =
               UserResolver.resolve(:telegram, "not-a-number")
    end

    test "rejects Telegram ID with special characters" do
      assert {:error, :invalid_platform_id} =
               UserResolver.resolve(:telegram, "123;DROP TABLE")
    end

    test "rejects Telegram ID exceeding 20 digits" do
      assert {:error, :invalid_platform_id} =
               UserResolver.resolve(:telegram, String.duplicate("1", 21))
    end

    test "accepts valid Telegram ID" do
      assert {:ok, _} = UserResolver.resolve(:telegram, "123456789")
    end

    test "rejects lowercase Slack ID" do
      assert {:error, :invalid_platform_id} =
               UserResolver.resolve(:slack, "u0abcdefg")
    end

    test "rejects Slack ID with special characters" do
      assert {:error, :invalid_platform_id} =
               UserResolver.resolve(:slack, "U0ABC!@#")
    end

    test "accepts valid Slack ID" do
      assert {:ok, _} = UserResolver.resolve(:slack, "U0ABCDEFG")
    end

    test "rejects non-numeric Discord ID" do
      assert {:error, :invalid_platform_id} =
               UserResolver.resolve(:discord, "abc123")
    end

    test "accepts valid Discord ID" do
      assert {:ok, _} = UserResolver.resolve(:discord, "987654321012345678")
    end

    test "rejects Google Chat ID without users/ prefix" do
      assert {:error, :invalid_platform_id} =
               UserResolver.resolve(:google_chat, "112233445566")
    end

    test "accepts valid Google Chat ID" do
      assert {:ok, _} = UserResolver.resolve(:google_chat, "users/112233445566")
    end

    test "unknown channel passes through without validation" do
      # Unknown channels have no pattern — validation is skipped
      assert {:ok, _} = UserResolver.resolve(:unknown_channel, "anything-goes")
    end
  end

  # ---------------------------------------------------------------
  # P1: link_identity/4 — cross-channel identity linking
  # ---------------------------------------------------------------

  describe "link_identity/4" do
    test "links a new identity to an existing user" do
      {user, _identity, _conversation} = user_with_conversation_fixture()

      assert {:ok, %UserIdentity{} = new_id} =
               UserResolver.link_identity(user.id, :discord, "987654321012345678")

      assert new_id.user_id == user.id
      assert new_id.channel == "discord"
      assert new_id.external_id == "987654321012345678"
    end

    test "linked identity resolves to the same user" do
      {user, _identity, conversation} = user_with_conversation_fixture()

      {:ok, _} = UserResolver.link_identity(user.id, :discord, "111222333444555")

      # Resolve via the newly linked identity
      {:ok, result} = UserResolver.resolve(:discord, "111222333444555")

      assert result.user_id == user.id
      assert result.conversation_id == conversation.id
    end

    test "rejects duplicate identity linking" do
      {user, _identity, _conversation} = user_with_conversation_fixture()

      {:ok, _} = UserResolver.link_identity(user.id, :discord, "111222333444555")

      assert {:error, %Ecto.Changeset{}} =
               UserResolver.link_identity(user.id, :discord, "111222333444555")
    end

    test "validates platform ID format" do
      {user, _identity, _conversation} = user_with_conversation_fixture()

      assert {:error, :invalid_platform_id} =
               UserResolver.link_identity(user.id, :telegram, "not-numeric")
    end

    test "links identity with space_id" do
      {user, _identity, _conversation} = user_with_conversation_fixture()

      {:ok, identity} =
        UserResolver.link_identity(user.id, :slack, "U0NEWSLACK", "T0WORKSPACE")

      assert identity.space_id == "T0WORKSPACE"
    end
  end

  # ---------------------------------------------------------------
  # P2: space_id-aware identity resolution
  # ---------------------------------------------------------------

  describe "resolve/3 — space_id scoping" do
    test "same external_id in different spaces resolves to different users" do
      # Create user in workspace A
      {:ok, %{user_id: user_a}} =
        UserResolver.resolve(:slack, "U0SAMEUSER", %{space_id: "T0WORKSPACE_A"})

      # Create user in workspace B (same Slack user ID, different space)
      {:ok, %{user_id: user_b}} =
        UserResolver.resolve(:slack, "U0SAMEUSER", %{space_id: "T0WORKSPACE_B"})

      refute user_a == user_b
    end

    test "resolving with space_id finds the correct identity" do
      # Create two identities for the same external_id in different spaces
      {:ok, %{user_id: user_a}} =
        UserResolver.resolve(:slack, "U0LOOKUP", %{space_id: "T0SPACEA"})

      {:ok, %{user_id: user_b}} =
        UserResolver.resolve(:slack, "U0LOOKUP", %{space_id: "T0SPACEB"})

      # Re-resolve each — should find the correct one
      {:ok, %{user_id: found_a}} =
        UserResolver.resolve(:slack, "U0LOOKUP", %{space_id: "T0SPACEA"})

      {:ok, %{user_id: found_b}} =
        UserResolver.resolve(:slack, "U0LOOKUP", %{space_id: "T0SPACEB"})

      assert found_a == user_a
      assert found_b == user_b
    end

    test "nil space_id identity gets adopted by first real space_id (self-healing)" do
      # Create identity with no space_id (e.g., backfilled migration row)
      {:ok, %{user_id: user_nil}} =
        UserResolver.resolve(:telegram, "777888999")

      # Resolve with a real space_id — fallback matches the NULL row and backfills
      {:ok, %{user_id: user_spaced}} =
        UserResolver.resolve(:telegram, "777888999", %{space_id: "some_space"})

      # Same user — the NULL row was healed, not duplicated
      assert user_nil == user_spaced

      # A second different space_id creates a new user (no NULL row left to adopt)
      {:ok, %{user_id: user_other}} =
        UserResolver.resolve(:telegram, "777888999", %{space_id: "other_space"})

      refute user_spaced == user_other
    end

    test "nil space_id backwards compatible — existing no-space lookups still work" do
      {:ok, %{user_id: user_id}} = UserResolver.resolve(:telegram, "111000222")

      # Second resolve without space_id should find the same user
      {:ok, %{user_id: found_id}} = UserResolver.resolve(:telegram, "111000222")

      assert user_id == found_id
    end
  end

  # ---------------------------------------------------------------
  # P2: space_id fallback — self-healing backfilled NULL space_id rows
  # ---------------------------------------------------------------

  describe "resolve/3 — space_id fallback (self-healing)" do
    test "matches existing identity with NULL space_id when message has real space_id" do
      # Simulate a backfilled identity with NULL space_id
      user = chat_user_fixture(%{channel: "telegram", external_id: "550011223"})
      _identity = user_identity_fixture(user, %{space_id: nil})

      # Create perpetual conversation so resolve returns it
      now = DateTime.utc_now()

      {:ok, conversation} =
        %Conversation{}
        |> Conversation.changeset(%{
          channel: "unified",
          user_id: user.id,
          agent_type: "orchestrator",
          status: "active",
          started_at: now,
          last_active_at: now
        })
        |> Repo.insert()

      # Resolve with a real space_id — should find the NULL row via fallback
      assert {:ok, %{user_id: found_user_id, conversation_id: found_conv_id}} =
               UserResolver.resolve(:telegram, "550011223", %{space_id: "some_chat_id"})

      assert found_user_id == user.id
      assert found_conv_id == conversation.id
    end

    test "backfills space_id on the identity row after fallback match" do
      user = chat_user_fixture(%{channel: "telegram", external_id: "660011223"})
      identity = user_identity_fixture(user, %{space_id: nil})

      assert is_nil(identity.space_id)

      {:ok, _} =
        UserResolver.resolve(:telegram, "660011223", %{space_id: "healed_space"})

      # Reload identity from DB — space_id should be backfilled
      updated = Repo.get!(UserIdentity, identity.id)
      assert updated.space_id == "healed_space"
    end

    test "subsequent lookups use exact match after backfill (no fallback needed)" do
      user = chat_user_fixture(%{channel: "telegram", external_id: "770011223"})
      _identity = user_identity_fixture(user, %{space_id: nil})

      # First call triggers fallback + backfill
      {:ok, result1} =
        UserResolver.resolve(:telegram, "770011223", %{space_id: "real_space"})

      # Second call should find via exact match (space_id is now "real_space")
      {:ok, result2} =
        UserResolver.resolve(:telegram, "770011223", %{space_id: "real_space"})

      assert result1.user_id == result2.user_id
      assert result1.user_id == user.id
    end

    test "does not false-match when identities have different real space_ids" do
      # Create identity with space_id "A"
      {:ok, %{user_id: user_a}} =
        UserResolver.resolve(:slack, "U0FALLBACK", %{space_id: "T0SPACEA"})

      # Create identity with space_id "B" (different user)
      {:ok, %{user_id: user_b}} =
        UserResolver.resolve(:slack, "U0FALLBACK", %{space_id: "T0SPACEB"})

      refute user_a == user_b

      # Neither should trigger fallback — both have real space_ids
      {:ok, %{user_id: found_a}} =
        UserResolver.resolve(:slack, "U0FALLBACK", %{space_id: "T0SPACEA"})

      {:ok, %{user_id: found_b}} =
        UserResolver.resolve(:slack, "U0FALLBACK", %{space_id: "T0SPACEB"})

      assert found_a == user_a
      assert found_b == user_b
    end

    test "fallback does not fire when space_id is nil (exact nil match only)" do
      # Create identity with NULL space_id
      user = chat_user_fixture(%{channel: "telegram", external_id: "880011223"})
      _identity = user_identity_fixture(user, %{space_id: nil})

      # Resolve with nil space_id — should use exact nil match, not fallback
      {:ok, %{user_id: found_id}} = UserResolver.resolve(:telegram, "880011223")

      assert found_id == user.id
    end
  end

  # ---------------------------------------------------------------
  # P1: race condition handling
  # ---------------------------------------------------------------

  describe "resolve/3 — concurrent first messages" do
    test "concurrent resolves for same identity converge to same user" do
      # Must be a valid Telegram numeric ID
      external_id = "#{System.unique_integer([:positive])}"

      # Simulate concurrent first-contact resolution
      tasks =
        for _i <- 1..5 do
          Task.async(fn ->
            UserResolver.resolve(:telegram, external_id)
          end)
        end

      results = Task.await_many(tasks, 5_000)

      # All should succeed
      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)

      # All should resolve to the same user_id
      user_ids = Enum.map(results, fn {:ok, %{user_id: uid}} -> uid end)
      assert length(Enum.uniq(user_ids)) == 1

      # All should resolve to the same conversation_id
      conv_ids = Enum.map(results, fn {:ok, %{conversation_id: cid}} -> cid end)
      assert length(Enum.uniq(conv_ids)) == 1
    end
  end
end

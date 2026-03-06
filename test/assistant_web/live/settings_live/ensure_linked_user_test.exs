# test/assistant_web/live/settings_live/ensure_linked_user_test.exs — Tests for
# the ensure_linked_user identity resolution state machine.
#
# CRITICAL coverage target: 85%+ (identity bridge, security boundary).
# Tests the full state machine: real user → done, pseudo → upgrade,
# nil → email match or create pseudo.
#
# Related files:
#   - lib/assistant_web/live/settings_live/context.ex (module under test)
#   - lib/assistant/channels/user_resolver.ex (upgrade_pseudo_user)
#   - lib/assistant/schemas/user.ex (email field)
#   - lib/assistant/accounts/settings_user.ex

defmodule AssistantWeb.SettingsLive.EnsureLinkedUserTest do
  use Assistant.DataCase, async: true

  alias AssistantWeb.SettingsLive.Context
  alias Assistant.Schemas.{Conversation, User}

  import Assistant.AccountsFixtures
  import Assistant.ChannelFixtures

  # ---------------------------------------------------------------
  # P0: settings_user already linked to real user → immediate return
  # ---------------------------------------------------------------

  describe "ensure_linked_user/1 — real user link" do
    test "returns user_id immediately when linked to a real (non-pseudo) user" do
      real_user = chat_user_fixture(%{channel: "google_chat", external_id: "users/real_001"})
      settings_user = settings_user_fixture()

      settings_user =
        settings_user
        |> Ecto.Changeset.change(%{user_id: real_user.id})
        |> Repo.update!()

      assert {:ok, user_id} = Context.ensure_linked_user(settings_user)
      assert user_id == real_user.id
    end

    test "returns same user_id on repeated calls (idempotent)" do
      real_user =
        chat_user_fixture(%{
          channel: "telegram",
          external_id: "#{System.unique_integer([:positive])}"
        })
      settings_user = settings_user_fixture()

      settings_user =
        settings_user
        |> Ecto.Changeset.change(%{user_id: real_user.id})
        |> Repo.update!()

      {:ok, id1} = Context.ensure_linked_user(settings_user)
      {:ok, id2} = Context.ensure_linked_user(settings_user)
      {:ok, id3} = Context.ensure_linked_user(settings_user)

      assert id1 == id2
      assert id2 == id3
      assert id1 == real_user.id
    end
  end

  # ---------------------------------------------------------------
  # P0: settings_user linked to pseudo-user → upgrade via email
  # ---------------------------------------------------------------

  describe "ensure_linked_user/1 — pseudo-user upgrade" do
    test "upgrades to real user when email matches a real chat user" do
      email = "upgrade-match-#{System.unique_integer([:positive])}@example.com"

      # Create a real chat user with the same email
      real_user =
        chat_user_fixture(%{
          channel: "google_chat",
          external_id: "users/real_upgrade_#{System.unique_integer([:positive])}",
          email: String.downcase(email)
        })

      # Create a pseudo-user linked to the settings_user
      pseudo_user =
        chat_user_fixture(%{
          channel: "settings",
          external_id: "settings:pseudo_#{System.unique_integer([:positive])}"
        })

      # Create a settings_user with that email, linked to the pseudo
      settings_user = settings_user_fixture(%{email: email})

      settings_user =
        settings_user
        |> Ecto.Changeset.change(%{user_id: pseudo_user.id})
        |> Repo.update!()

      assert {:ok, user_id} = Context.ensure_linked_user(settings_user)

      # Should be the real user, not the pseudo
      assert user_id == real_user.id

      # Pseudo-user should be archived
      updated_pseudo = Repo.get!(User, pseudo_user.id)
      assert updated_pseudo.channel == "settings:archived"
    end

    test "keeps pseudo-user when no email match exists" do
      # Create a pseudo-user
      pseudo_user =
        chat_user_fixture(%{
          channel: "settings",
          external_id: "settings:keep_#{System.unique_integer([:positive])}"
        })

      # Settings user with email that doesn't match any real user
      settings_user =
        settings_user_fixture(%{
          email: "no-match-#{System.unique_integer([:positive])}@example.com"
        })

      settings_user =
        settings_user
        |> Ecto.Changeset.change(%{user_id: pseudo_user.id})
        |> Repo.update!()

      assert {:ok, user_id} = Context.ensure_linked_user(settings_user)

      # Should keep the pseudo-user
      assert user_id == pseudo_user.id
    end

    test "conversations survive pseudo-user upgrade" do
      email = "conv-survive-#{System.unique_integer([:positive])}@example.com"

      # Create a pseudo-user with a conversation
      pseudo_user = chat_user_fixture(%{
        channel: "settings",
        external_id: "settings:conv_#{System.unique_integer([:positive])}"
      })

      now = DateTime.utc_now()

      {:ok, conv} =
        %Conversation{}
        |> Conversation.changeset(%{
          channel: "unified",
          user_id: pseudo_user.id,
          agent_type: "orchestrator",
          status: "active",
          started_at: now,
          last_active_at: now
        })
        |> Repo.insert()

      # Add messages to the conversation
      {:ok, _msgs} = Assistant.Memory.Store.batch_append_messages(conv.id, [
        %{role: "user", content: "Hello before upgrade"},
        %{role: "assistant", content: "Hi there before upgrade"}
      ])

      # Create a real user with matching email
      real_user = chat_user_fixture(%{
        channel: "google_chat",
        external_id: "users/real_conv_#{System.unique_integer([:positive])}",
        email: String.downcase(email)
      })

      # Link settings_user to pseudo
      settings_user = settings_user_fixture(%{email: email})

      settings_user =
        settings_user
        |> Ecto.Changeset.change(%{user_id: pseudo_user.id})
        |> Repo.update!()

      assert {:ok, user_id} = Context.ensure_linked_user(settings_user)
      assert user_id == real_user.id

      # Conversation should now belong to the real user
      updated_conv = Repo.get!(Conversation, conv.id)
      assert updated_conv.user_id == real_user.id

      # Messages should still be there
      messages = Assistant.Memory.Store.list_messages(conv.id, limit: 10, order: :asc)
      assert length(messages) == 2
      assert hd(messages).content == "Hello before upgrade"
    end
  end

  # ---------------------------------------------------------------
  # P0: settings_user with nil user_id → email match or create pseudo
  # ---------------------------------------------------------------

  describe "ensure_linked_user/1 — nil user_id" do
    test "links to existing real user by email match" do
      email = "nil-link-#{System.unique_integer([:positive])}@example.com"

      # Real chat user with this email
      real_user = chat_user_fixture(%{
        channel: "telegram",
        external_id: "#{System.unique_integer([:positive])}",
        email: String.downcase(email)
      })

      # Settings user with no user_id but matching email
      settings_user = settings_user_fixture(%{email: email})
      assert is_nil(settings_user.user_id)

      assert {:ok, user_id} = Context.ensure_linked_user(settings_user)
      assert user_id == real_user.id

      # settings_user should now be linked
      reloaded = Repo.get!(Assistant.Accounts.SettingsUser, settings_user.id)
      assert reloaded.user_id == real_user.id
    end

    test "creates pseudo-user when no email match exists" do
      settings_user = settings_user_fixture(%{
        email: "new-pseudo-#{System.unique_integer([:positive])}@example.com"
      })

      assert is_nil(settings_user.user_id)

      assert {:ok, user_id} = Context.ensure_linked_user(settings_user)

      # Should have created a pseudo-user
      pseudo = Repo.get!(User, user_id)
      assert pseudo.channel == "settings"
      assert pseudo.external_id =~ "settings:"

      # settings_user should now be linked
      reloaded = Repo.get!(Assistant.Accounts.SettingsUser, settings_user.id)
      assert reloaded.user_id == user_id
    end

    test "creates pseudo-user when settings_user has nil email" do
      settings_user = settings_user_fixture()

      # Nil out the email to simulate edge case
      settings_user =
        settings_user
        |> Ecto.Changeset.change(%{user_id: nil})
        |> Repo.update!()

      assert {:ok, user_id} = Context.ensure_linked_user(settings_user)

      pseudo = Repo.get!(User, user_id)
      assert pseudo.channel == "settings"
    end
  end

  # ---------------------------------------------------------------
  # P0: stale reference handling
  # ---------------------------------------------------------------

  describe "ensure_linked_user/1 — stale reference" do
    test "handles stale user_id (user deleted) by trying email match" do
      email = "stale-#{System.unique_integer([:positive])}@example.com"

      # Create a real user with matching email
      real_user = chat_user_fixture(%{
        channel: "google_chat",
        external_id: "users/stale_#{System.unique_integer([:positive])}",
        email: String.downcase(email)
      })

      # Create a temporary user that we'll delete to produce a stale reference
      temp_user = chat_user_fixture(%{
        channel: "telegram",
        external_id: "#{System.unique_integer([:positive])}"
      })

      settings_user = settings_user_fixture(%{email: email})

      settings_user =
        settings_user
        |> Ecto.Changeset.change(%{user_id: temp_user.id})
        |> Repo.update!()

      # Delete the temp user to create the stale reference
      # Need to unlink settings_user first to allow delete, then re-link
      settings_user
      |> Ecto.Changeset.change(%{user_id: nil})
      |> Repo.update!()

      Repo.delete!(temp_user)

      # Re-set the stale user_id via raw SQL — disable FK check temporarily
      {:ok, temp_uid_bin} = Ecto.UUID.dump(temp_user.id)
      {:ok, su_id_bin} = Ecto.UUID.dump(settings_user.id)

      Ecto.Adapters.SQL.query!(Repo,
        "ALTER TABLE settings_users DISABLE TRIGGER ALL", [])

      Ecto.Adapters.SQL.query!(Repo,
        "UPDATE settings_users SET user_id = $1 WHERE id = $2",
        [temp_uid_bin, su_id_bin])

      Ecto.Adapters.SQL.query!(Repo,
        "ALTER TABLE settings_users ENABLE TRIGGER ALL", [])

      # Reload settings_user with stale reference
      stale_su = Repo.get!(Assistant.Accounts.SettingsUser, settings_user.id)
      assert stale_su.user_id == temp_user.id

      assert {:ok, user_id} = Context.ensure_linked_user(stale_su)
      assert user_id == real_user.id
    end

    test "handles archived pseudo-user by trying email match fresh" do
      email = "archived-#{System.unique_integer([:positive])}@example.com"

      # Archived pseudo-user
      archived_pseudo = chat_user_fixture(%{
        channel: "settings:archived",
        external_id: "settings:archived_#{System.unique_integer([:positive])}"
      })

      settings_user = settings_user_fixture(%{email: email})

      settings_user =
        settings_user
        |> Ecto.Changeset.change(%{user_id: archived_pseudo.id})
        |> Repo.update!()

      # No matching real user, so should create a new pseudo
      assert {:ok, user_id} = Context.ensure_linked_user(settings_user)
      refute user_id == archived_pseudo.id

      new_pseudo = Repo.get!(User, user_id)
      assert new_pseudo.channel == "settings"
    end
  end

  # ---------------------------------------------------------------
  # P1: ordering scenarios
  # ---------------------------------------------------------------

  describe "ensure_linked_user/1 — ordering scenarios" do
    test "settings_user first, then GChat with matching email → pseudo upgraded via resolver" do
      email = "order-su-first-#{System.unique_integer([:positive])}@example.com"

      # Step 1: settings_user registers → gets a pseudo-user
      settings_user = settings_user_fixture(%{email: email})

      settings_user =
        settings_user
        |> Ecto.Changeset.change(%{user_id: nil})
        |> Repo.update!()

      {:ok, pseudo_user_id} = Context.ensure_linked_user(settings_user)

      pseudo = Repo.get!(User, pseudo_user_id)
      assert pseudo.channel == "settings"

      # Step 2: GChat message arrives with matching email → UserResolver creates real user and upgrades pseudo
      external_id = "users/order_#{System.unique_integer([:positive])}"

      {:ok, %{user_id: resolved_user_id}} =
        Assistant.Channels.UserResolver.resolve(:google_chat, external_id, %{
          user_email: email,
          display_name: "GChat User",
          space_id: "spaces/ORDER"
        })

      # Should be a different (real) user, not the pseudo
      refute resolved_user_id == pseudo_user_id

      real_user = Repo.get!(User, resolved_user_id)
      assert real_user.channel == "google_chat"

      # Pseudo should be archived
      updated_pseudo = Repo.get!(User, pseudo_user_id)
      assert updated_pseudo.channel == "settings:archived"

      # settings_user should now be linked to the real user
      reloaded_su = Repo.get!(Assistant.Accounts.SettingsUser, settings_user.id)
      assert reloaded_su.user_id == resolved_user_id
    end

    test "GChat first, then settings_user login → email match links" do
      email = "order-gc-first-#{System.unique_integer([:positive])}@example.com"

      # Step 1: GChat message arrives first → creates user with email
      external_id = "users/gcfirst_#{System.unique_integer([:positive])}"

      {:ok, %{user_id: gchat_user_id}} =
        Assistant.Channels.UserResolver.resolve(:google_chat, external_id, %{
          user_email: email,
          display_name: "GChat First",
          space_id: "spaces/GCFIRST"
        })

      real_user = Repo.get!(User, gchat_user_id)
      assert real_user.channel == "google_chat"
      assert real_user.email == String.downcase(email)

      # Step 2: settings_user registers with same email (no user_id yet)
      settings_user = settings_user_fixture(%{email: email})

      settings_user =
        settings_user
        |> Ecto.Changeset.change(%{user_id: nil})
        |> Repo.update!()

      {:ok, linked_user_id} = Context.ensure_linked_user(settings_user)

      # Should link to the existing GChat user
      assert linked_user_id == gchat_user_id
    end
  end

  # ---------------------------------------------------------------
  # P1: multi-user isolation
  # ---------------------------------------------------------------

  describe "ensure_linked_user/1 — multi-user isolation" do
    test "different settings_users link to different chat users" do
      email_a = "iso-a-#{System.unique_integer([:positive])}@example.com"
      email_b = "iso-b-#{System.unique_integer([:positive])}@example.com"

      user_a = chat_user_fixture(%{
        channel: "google_chat",
        external_id: "users/iso_a_#{System.unique_integer([:positive])}",
        email: String.downcase(email_a)
      })

      user_b = chat_user_fixture(%{
        channel: "google_chat",
        external_id: "users/iso_b_#{System.unique_integer([:positive])}",
        email: String.downcase(email_b)
      })

      su_a = settings_user_fixture(%{email: email_a})
      su_a = su_a |> Ecto.Changeset.change(%{user_id: nil}) |> Repo.update!()

      su_b = settings_user_fixture(%{email: email_b})
      su_b = su_b |> Ecto.Changeset.change(%{user_id: nil}) |> Repo.update!()

      {:ok, id_a} = Context.ensure_linked_user(su_a)
      {:ok, id_b} = Context.ensure_linked_user(su_b)

      assert id_a == user_a.id
      assert id_b == user_b.id
      refute id_a == id_b
    end

    test "multiple chat users (Telegram + GChat) → uses email, not count heuristic" do
      email = "multi-chan-#{System.unique_integer([:positive])}@example.com"

      # Create a Telegram user (no email)
      _tg_user = chat_user_fixture(%{
        channel: "telegram",
        external_id: "#{System.unique_integer([:positive])}"
      })

      # Create a GChat user WITH email
      gchat_user = chat_user_fixture(%{
        channel: "google_chat",
        external_id: "users/multi_#{System.unique_integer([:positive])}",
        email: String.downcase(email)
      })

      # Settings user with the GChat user's email
      settings_user = settings_user_fixture(%{email: email})
      settings_user = settings_user |> Ecto.Changeset.change(%{user_id: nil}) |> Repo.update!()

      {:ok, linked_id} = Context.ensure_linked_user(settings_user)

      # Should link to the GChat user by email, not the Telegram user by count
      assert linked_id == gchat_user.id
    end
  end

  # ---------------------------------------------------------------
  # P2: email case insensitivity
  # ---------------------------------------------------------------

  describe "ensure_linked_user/1 — email case insensitivity" do
    test "matches email regardless of case" do
      lower_email = "case-test-#{System.unique_integer([:positive])}@example.com"

      real_user = chat_user_fixture(%{
        channel: "google_chat",
        external_id: "users/case_#{System.unique_integer([:positive])}",
        email: lower_email
      })

      # Settings user with UPPER CASE email
      upper_email = String.upcase(lower_email)
      settings_user = settings_user_fixture(%{email: upper_email})
      settings_user = settings_user |> Ecto.Changeset.change(%{user_id: nil}) |> Repo.update!()

      {:ok, linked_id} = Context.ensure_linked_user(settings_user)
      assert linked_id == real_user.id
    end
  end
end

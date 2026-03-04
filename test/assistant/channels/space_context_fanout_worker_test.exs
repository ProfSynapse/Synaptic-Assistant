# test/assistant/channels/space_context_fanout_worker_test.exs — Smoke tests
# for SpaceContextFanoutWorker.
#
# Verifies: module compiles, DM-space guard works, fan-out injects messages
# into recipients' perpetual conversations.
#
# Related files:
#   - lib/assistant/channels/space_context_fanout_worker.ex (module under test)
#   - lib/assistant/channels/dispatcher.ex (enqueues this worker)
#   - lib/assistant/memory/store.ex (conversation/message persistence)

defmodule Assistant.Channels.SpaceContextFanoutWorkerTest do
  use Assistant.DataCase, async: true

  alias Assistant.Channels.SpaceContextFanoutWorker
  alias Assistant.Schemas.{Message, UserIdentity}

  import Assistant.ChannelFixtures

  # ---------------------------------------------------------------
  # Module compilation smoke test
  # ---------------------------------------------------------------

  describe "module compilation" do
    test "module is loaded and defines Oban.Worker callbacks" do
      assert Code.ensure_loaded?(SpaceContextFanoutWorker)
      assert function_exported?(SpaceContextFanoutWorker, :perform, 1)
      assert function_exported?(SpaceContextFanoutWorker, :new, 1)
    end
  end

  # ---------------------------------------------------------------
  # DM space guard — should skip without errors
  # ---------------------------------------------------------------

  describe "perform/1 — DM space guard" do
    test "skips DM space (v1 type)" do
      job = %Oban.Job{
        args: %{
          "space_id" => "spaces/DM123",
          "sender_user_id" => Ecto.UUID.generate(),
          "sender_email" => "sender@example.com",
          "sender_display_name" => "Sender",
          "question" => "Hello?",
          "response" => "Hi there!",
          "space_type" => "DM"
        }
      }

      assert :ok = SpaceContextFanoutWorker.perform(job)
    end

    test "skips DIRECT_MESSAGE space (v2 type)" do
      job = %Oban.Job{
        args: %{
          "space_id" => "spaces/DM456",
          "sender_user_id" => Ecto.UUID.generate(),
          "sender_email" => "sender@example.com",
          "sender_display_name" => "Sender",
          "question" => "Hello?",
          "response" => "Hi there!",
          "space_type" => "DIRECT_MESSAGE"
        }
      }

      assert :ok = SpaceContextFanoutWorker.perform(job)
    end
  end

  # ---------------------------------------------------------------
  # Fan-out — injects context messages into recipients' conversations
  # ---------------------------------------------------------------

  describe "perform/1 — fan-out to space members" do
    test "returns :ok with no recipients when space has no other members" do
      sender = chat_user_fixture(%{channel: "google_chat", external_id: "users/sender_solo"})

      job = %Oban.Job{
        args: %{
          "space_id" => "spaces/EMPTY_SPACE",
          "sender_user_id" => sender.id,
          "sender_email" => "sender@example.com",
          "sender_display_name" => "Sender",
          "question" => "Anyone here?",
          "response" => "I can help you.",
          "space_type" => "SPACE"
        }
      }

      assert :ok = SpaceContextFanoutWorker.perform(job)
    end

    test "injects paired messages into recipients' perpetual conversations" do
      space_id = "spaces/SHARED_#{System.unique_integer([:positive])}"

      # Create sender
      sender = chat_user_fixture(%{channel: "google_chat", external_id: "users/fanout_sender"})

      user_identity_fixture(sender, %{
        channel: "google_chat",
        external_id: "users/fanout_sender",
        space_id: space_id
      })

      # Create recipient (another member of the same space)
      recipient = chat_user_fixture(%{channel: "google_chat", external_id: "users/fanout_recipient"})

      user_identity_fixture(recipient, %{
        channel: "google_chat",
        external_id: "users/fanout_recipient",
        space_id: space_id
      })

      # Ensure recipient has a perpetual conversation
      {:ok, _conv} = Assistant.Memory.Store.get_or_create_perpetual_conversation(recipient.id)

      job = %Oban.Job{
        args: %{
          "space_id" => space_id,
          "sender_user_id" => sender.id,
          "sender_email" => "sender@example.com",
          "sender_display_name" => "Alice",
          "question" => "What is the project deadline?",
          "response" => "The deadline is March 15.",
          "space_type" => "SPACE"
        }
      }

      assert :ok = SpaceContextFanoutWorker.perform(job)

      # Verify messages were injected into recipient's conversation
      {:ok, conv} = Assistant.Memory.Store.get_or_create_perpetual_conversation(recipient.id)

      messages =
        from(m in Message,
          where: m.conversation_id == ^conv.id,
          where: m.role == "system",
          order_by: [asc: m.inserted_at]
        )
        |> Repo.all()

      # Should have exactly 2 system messages (question + response)
      assert length(messages) == 2

      [q_msg, r_msg] = messages

      assert q_msg.content =~ "What is the project deadline?"
      assert q_msg.metadata["type"] == "space_context"
      assert q_msg.metadata["sub_type"] == "question"
      assert q_msg.metadata["source"]["sender_display_name"] == "Alice"

      assert r_msg.content =~ "The deadline is March 15."
      assert r_msg.metadata["type"] == "space_context"
      assert r_msg.metadata["sub_type"] == "response"
    end

    test "excludes members with left_at set (soft-deleted)" do
      space_id = "spaces/LEFT_#{System.unique_integer([:positive])}"

      # Create sender
      sender = chat_user_fixture(%{channel: "google_chat", external_id: "users/left_sender"})

      user_identity_fixture(sender, %{
        channel: "google_chat",
        external_id: "users/left_sender",
        space_id: space_id
      })

      # Create a member who has left (left_at is set)
      left_member = chat_user_fixture(%{channel: "google_chat", external_id: "users/left_member"})

      %UserIdentity{}
      |> UserIdentity.changeset(%{
        user_id: left_member.id,
        channel: "google_chat",
        external_id: "users/left_member",
        space_id: space_id
      })
      |> Ecto.Changeset.put_change(:left_at, DateTime.utc_now())
      |> Repo.insert!()

      # Ensure left_member has a conversation (to confirm messages are NOT injected)
      {:ok, _conv} = Assistant.Memory.Store.get_or_create_perpetual_conversation(left_member.id)

      job = %Oban.Job{
        args: %{
          "space_id" => space_id,
          "sender_user_id" => sender.id,
          "sender_email" => "sender@example.com",
          "sender_display_name" => "Bob",
          "question" => "Test question",
          "response" => "Test response",
          "space_type" => "SPACE"
        }
      }

      assert :ok = SpaceContextFanoutWorker.perform(job)

      # Verify NO messages were injected for the left member
      {:ok, conv} = Assistant.Memory.Store.get_or_create_perpetual_conversation(left_member.id)

      messages =
        from(m in Message,
          where: m.conversation_id == ^conv.id,
          where: m.role == "system"
        )
        |> Repo.all()

      assert messages == []
    end

    test "fans out to multiple recipients in same space" do
      space_id = "spaces/MULTI_#{System.unique_integer([:positive])}"

      sender = chat_user_fixture(%{channel: "google_chat", external_id: "users/multi_sender_#{System.unique_integer([:positive])}"})

      user_identity_fixture(sender, %{
        channel: "google_chat",
        external_id: sender.external_id,
        space_id: space_id
      })

      # Create 3 recipients
      recipients =
        for i <- 1..3 do
          ext = "users/multi_r#{i}_#{System.unique_integer([:positive])}"
          r = chat_user_fixture(%{channel: "google_chat", external_id: ext})

          user_identity_fixture(r, %{
            channel: "google_chat",
            external_id: ext,
            space_id: space_id
          })

          {:ok, _conv} = Assistant.Memory.Store.get_or_create_perpetual_conversation(r.id)
          r
        end

      job = %Oban.Job{
        args: %{
          "space_id" => space_id,
          "sender_user_id" => sender.id,
          "sender_email" => "multi@example.com",
          "sender_display_name" => "Multi Sender",
          "question" => "Team meeting?",
          "response" => "Scheduling it now.",
          "space_type" => "SPACE"
        }
      }

      assert :ok = SpaceContextFanoutWorker.perform(job)

      # All 3 recipients should have 2 system messages each
      for recipient <- recipients do
        {:ok, conv} = Assistant.Memory.Store.get_or_create_perpetual_conversation(recipient.id)

        messages =
          from(m in Message,
            where: m.conversation_id == ^conv.id,
            where: m.role == "system"
          )
          |> Repo.all()

        assert length(messages) == 2,
               "Expected 2 messages for recipient #{recipient.id}, got #{length(messages)}"
      end

      # Sender should NOT have received context
      {:ok, sender_conv} = Assistant.Memory.Store.get_or_create_perpetual_conversation(sender.id)

      sender_msgs =
        from(m in Message,
          where: m.conversation_id == ^sender_conv.id,
          where: m.role == "system"
        )
        |> Repo.all()

      assert sender_msgs == []
    end

    test "does not inject into sender's own conversation (sender exclusion)" do
      space_id = "spaces/SENDER_EXCL_#{System.unique_integer([:positive])}"

      sender = chat_user_fixture(%{channel: "google_chat", external_id: "users/se_#{System.unique_integer([:positive])}"})

      user_identity_fixture(sender, %{
        channel: "google_chat",
        external_id: sender.external_id,
        space_id: space_id
      })

      {:ok, _conv} = Assistant.Memory.Store.get_or_create_perpetual_conversation(sender.id)

      job = %Oban.Job{
        args: %{
          "space_id" => space_id,
          "sender_user_id" => sender.id,
          "sender_email" => "sender@example.com",
          "sender_display_name" => "Sender",
          "question" => "Self test",
          "response" => "No self-inject",
          "space_type" => "SPACE"
        }
      }

      assert :ok = SpaceContextFanoutWorker.perform(job)

      {:ok, conv} = Assistant.Memory.Store.get_or_create_perpetual_conversation(sender.id)

      messages =
        from(m in Message,
          where: m.conversation_id == ^conv.id,
          where: m.role == "system"
        )
        |> Repo.all()

      assert messages == []
    end

    test "handles nil space_type gracefully (does not skip)" do
      space_id = "spaces/NIL_TYPE_#{System.unique_integer([:positive])}"

      sender = chat_user_fixture(%{channel: "google_chat", external_id: "users/nil_type_#{System.unique_integer([:positive])}"})

      user_identity_fixture(sender, %{
        channel: "google_chat",
        external_id: sender.external_id,
        space_id: space_id
      })

      recipient = chat_user_fixture(%{channel: "google_chat", external_id: "users/nil_type_r_#{System.unique_integer([:positive])}"})

      user_identity_fixture(recipient, %{
        channel: "google_chat",
        external_id: recipient.external_id,
        space_id: space_id
      })

      {:ok, _conv} = Assistant.Memory.Store.get_or_create_perpetual_conversation(recipient.id)

      # nil space_type should NOT be treated as DM
      job = %Oban.Job{
        args: %{
          "space_id" => space_id,
          "sender_user_id" => sender.id,
          "sender_email" => "sender@example.com",
          "sender_display_name" => "Sender",
          "question" => "nil type test",
          "response" => "should fan out",
          "space_type" => nil
        }
      }

      assert :ok = SpaceContextFanoutWorker.perform(job)

      {:ok, conv} = Assistant.Memory.Store.get_or_create_perpetual_conversation(recipient.id)

      messages =
        from(m in Message,
          where: m.conversation_id == ^conv.id,
          where: m.role == "system"
        )
        |> Repo.all()

      assert length(messages) == 2
    end

    test "different users in same space get own conversations (space scoping)" do
      space_id = "spaces/SCOPED_#{System.unique_integer([:positive])}"

      sender = chat_user_fixture(%{channel: "google_chat", external_id: "users/scoped_s_#{System.unique_integer([:positive])}"})

      user_identity_fixture(sender, %{
        channel: "google_chat",
        external_id: sender.external_id,
        space_id: space_id
      })

      user_a = chat_user_fixture(%{channel: "google_chat", external_id: "users/scoped_a_#{System.unique_integer([:positive])}"})

      user_identity_fixture(user_a, %{
        channel: "google_chat",
        external_id: user_a.external_id,
        space_id: space_id
      })

      user_b = chat_user_fixture(%{channel: "google_chat", external_id: "users/scoped_b_#{System.unique_integer([:positive])}"})

      user_identity_fixture(user_b, %{
        channel: "google_chat",
        external_id: user_b.external_id,
        space_id: space_id
      })

      {:ok, conv_a} = Assistant.Memory.Store.get_or_create_perpetual_conversation(user_a.id)
      {:ok, conv_b} = Assistant.Memory.Store.get_or_create_perpetual_conversation(user_b.id)

      # Conversations are separate
      refute conv_a.id == conv_b.id

      job = %Oban.Job{
        args: %{
          "space_id" => space_id,
          "sender_user_id" => sender.id,
          "sender_email" => "sender@example.com",
          "sender_display_name" => "Sender",
          "question" => "Scoping test",
          "response" => "Both get it separately",
          "space_type" => "SPACE"
        }
      }

      assert :ok = SpaceContextFanoutWorker.perform(job)

      # Each user should have messages in their OWN conversation
      msgs_a =
        from(m in Message,
          where: m.conversation_id == ^conv_a.id and m.role == "system"
        )
        |> Repo.all()

      msgs_b =
        from(m in Message,
          where: m.conversation_id == ^conv_b.id and m.role == "system"
        )
        |> Repo.all()

      assert length(msgs_a) == 2
      assert length(msgs_b) == 2
    end
  end

  # ---------------------------------------------------------------
  # CRITICAL: DM privacy — adversarial test
  # ---------------------------------------------------------------

  describe "perform/1 — DM privacy (CRITICAL)" do
    test "DM messages are NEVER fanned out even with space members present" do
      space_id = "spaces/DM_PRIV_#{System.unique_integer([:positive])}"

      sender = chat_user_fixture(%{channel: "google_chat", external_id: "users/dm_priv_s_#{System.unique_integer([:positive])}"})

      user_identity_fixture(sender, %{
        channel: "google_chat",
        external_id: sender.external_id,
        space_id: space_id
      })

      bystander = chat_user_fixture(%{channel: "google_chat", external_id: "users/dm_priv_b_#{System.unique_integer([:positive])}"})

      user_identity_fixture(bystander, %{
        channel: "google_chat",
        external_id: bystander.external_id,
        space_id: space_id
      })

      {:ok, _conv} = Assistant.Memory.Store.get_or_create_perpetual_conversation(bystander.id)

      # DM v1
      job_dm = %Oban.Job{
        args: %{
          "space_id" => space_id,
          "sender_user_id" => sender.id,
          "sender_email" => "private@example.com",
          "sender_display_name" => "Private Sender",
          "question" => "This is a private DM question",
          "response" => "This is a private DM answer",
          "space_type" => "DM"
        }
      }

      assert :ok = SpaceContextFanoutWorker.perform(job_dm)

      # DM v2
      job_direct = %Oban.Job{
        args: %{
          "space_id" => space_id,
          "sender_user_id" => sender.id,
          "sender_email" => "private@example.com",
          "sender_display_name" => "Private Sender",
          "question" => "Another private question",
          "response" => "Another private answer",
          "space_type" => "DIRECT_MESSAGE"
        }
      }

      assert :ok = SpaceContextFanoutWorker.perform(job_direct)

      # Bystander MUST NOT have any context messages
      {:ok, conv} = Assistant.Memory.Store.get_or_create_perpetual_conversation(bystander.id)

      messages =
        from(m in Message,
          where: m.conversation_id == ^conv.id,
          where: m.role == "system"
        )
        |> Repo.all()

      assert messages == [], "PRIVACY VIOLATION: DM context leaked to bystander!"
    end
  end
end

# test/assistant/workspace_space_context_test.exs — Tests for space context
# rendering in the Workspace feed.
#
# Verifies that space_context system messages are correctly rendered as
# feed items with :space_context type, source_label, and sub_type.
# Also verifies that non-space-context system messages are NOT rendered.
#
# Related files:
#   - lib/assistant/workspace.ex (build_message_item, build_feed)
#   - lib/assistant/channels/space_context_fanout_worker.ex (injects messages)

defmodule Assistant.WorkspaceSpaceContextTest do
  use Assistant.DataCase, async: true

  alias Assistant.Memory.Store
  alias Assistant.Workspace

  import Assistant.ChannelFixtures

  # ---------------------------------------------------------------
  # Space context messages appear in workspace feed
  # ---------------------------------------------------------------

  describe "load/2 — space context messages in feed" do
    test "renders space_context messages as feed items with correct structure" do
      user = chat_user_fixture(%{channel: "google_chat", external_id: "users/ws_ctx_#{System.unique_integer([:positive])}"})
      {:ok, conv} = Store.get_or_create_perpetual_conversation(user.id)

      # Insert space context paired messages (as SpaceContextFanoutWorker would)
      context_metadata = %{
        "type" => "space_context",
        "sub_type" => "question",
        "source" => %{
          "kind" => "space_context",
          "channel" => "google_chat",
          "space_id" => "spaces/WS_TEST",
          "sender_display_name" => "Alice",
          "sender_email" => "alice@example.com"
        }
      }

      {:ok, _msgs} = Store.batch_append_messages(conv.id, [
        %{
          role: "system",
          content: "[Space context from Alice] What is the deadline?",
          metadata: context_metadata
        },
        %{
          role: "system",
          content: "[Bot response] The deadline is March 15.",
          metadata: Map.put(context_metadata, "sub_type", "response")
        }
      ])

      assert {:ok, workspace} = Workspace.load(user.id)

      # Find space context items in feed
      space_items =
        Enum.filter(workspace.feed_items, fn item ->
          item.type == :space_context
        end)

      assert length(space_items) == 2

      [q_item, r_item] = space_items

      assert q_item.type == :space_context
      assert q_item.sub_type == :question
      assert q_item.role == :system
      assert q_item.content =~ "What is the deadline?"
      assert q_item.source_label == "Space: Alice"

      assert r_item.type == :space_context
      assert r_item.sub_type == :response
      assert r_item.content =~ "The deadline is March 15."
    end

    test "does NOT render regular system messages as feed items" do
      user = chat_user_fixture(%{channel: "telegram", external_id: "#{System.unique_integer([:positive])}"})
      {:ok, conv} = Store.get_or_create_perpetual_conversation(user.id)

      # Insert a regular system message (no space_context metadata)
      {:ok, _} = Store.batch_append_messages(conv.id, [
        %{role: "system", content: "System notification"}
      ])

      assert {:ok, workspace} = Workspace.load(user.id)

      # Regular system messages should NOT appear in feed
      system_items =
        Enum.filter(workspace.feed_items, fn item ->
          item.role == :system
        end)

      assert system_items == []
    end

    test "space context messages appear alongside normal user/assistant messages" do
      user = chat_user_fixture(%{channel: "google_chat", external_id: "users/ws_mixed_#{System.unique_integer([:positive])}"})
      {:ok, conv} = Store.get_or_create_perpetual_conversation(user.id)

      # Insert mixed messages
      {:ok, _} = Store.batch_append_messages(conv.id, [
        %{role: "user", content: "My own question"},
        %{role: "assistant", content: "My own answer"},
        %{
          role: "system",
          content: "[Space context from Bob] His question",
          metadata: %{
            "type" => "space_context",
            "sub_type" => "question",
            "source" => %{
              "kind" => "space_context",
              "sender_display_name" => "Bob"
            }
          }
        }
      ])

      assert {:ok, workspace} = Workspace.load(user.id)

      types = Enum.map(workspace.feed_items, & &1.type)

      assert :message in types
      assert :space_context in types
    end

    test "uses 'A colleague' as fallback when sender_display_name is missing" do
      user = chat_user_fixture(%{channel: "google_chat", external_id: "users/ws_noname_#{System.unique_integer([:positive])}"})
      {:ok, conv} = Store.get_or_create_perpetual_conversation(user.id)

      {:ok, _} = Store.batch_append_messages(conv.id, [
        %{
          role: "system",
          content: "[Space context from A colleague] Question text",
          metadata: %{
            "type" => "space_context",
            "sub_type" => "question",
            "source" => %{
              "kind" => "space_context"
              # no sender_display_name
            }
          }
        }
      ])

      assert {:ok, workspace} = Workspace.load(user.id)

      space_items = Enum.filter(workspace.feed_items, &(&1.type == :space_context))
      assert length(space_items) == 1

      [item] = space_items
      assert item.source_label == "Space: A colleague"
    end
  end
end

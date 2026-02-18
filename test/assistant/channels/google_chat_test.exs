# test/assistant/channels/google_chat_test.exs
#
# Tests for the Google Chat channel adapter's normalize/1 function.
# Verifies that raw Google Chat webhook payloads are correctly converted
# into normalized %Message{} structs for each supported event type.

defmodule Assistant.Channels.GoogleChatTest do
  use ExUnit.Case, async: true

  alias Assistant.Channels.GoogleChat
  alias Assistant.Channels.Message

  # ---------------------------------------------------------------
  # MESSAGE event
  # ---------------------------------------------------------------

  describe "normalize/1 MESSAGE event" do
    test "extracts content, user_id, space_id, and thread_id" do
      event = build_message_event()

      assert {:ok, %Message{} = msg} = GoogleChat.normalize(event)

      assert msg.channel == :google_chat
      assert msg.content == "Hello assistant"
      assert msg.user_id == "users/12345"
      assert msg.space_id == "spaces/AAAA"
      assert msg.thread_id == "spaces/AAAA/threads/xyz"
      assert msg.user_display_name == "Jane Doe"
      assert msg.user_email == "jane@example.com"
      assert msg.channel_message_id == "spaces/AAAA/messages/msg1"
    end

    test "uses argumentText over text when available" do
      event = build_message_event(%{
        "message" => %{
          "name" => "spaces/AAAA/messages/msg1",
          "text" => "@Bot do something",
          "argumentText" => "do something",
          "sender" => %{"name" => "users/1", "displayName" => "User"},
          "thread" => %{"name" => "spaces/AAAA/threads/t1"}
        }
      })

      {:ok, msg} = GoogleChat.normalize(event)
      assert msg.content == "do something"
      assert msg.argument_text == "do something"
    end

    test "trims whitespace from content" do
      event = build_message_event(%{
        "message" => %{
          "name" => "spaces/AAAA/messages/msg1",
          "text" => "  spaced out  ",
          "sender" => %{"name" => "users/1"},
          "thread" => %{"name" => "spaces/AAAA/threads/t1"}
        }
      })

      {:ok, msg} = GoogleChat.normalize(event)
      assert msg.content == "spaced out"
    end

    test "sets metadata with event_type, space_type, event_time" do
      event = build_message_event()

      {:ok, msg} = GoogleChat.normalize(event)

      assert msg.metadata["event_type"] == "MESSAGE"
      assert msg.metadata["space_type"] == "DM"
      assert msg.metadata["event_time"] == "2026-02-18T10:00:00Z"
    end

    test "parses timestamp from eventTime" do
      event = build_message_event()
      {:ok, msg} = GoogleChat.normalize(event)

      assert %DateTime{year: 2026, month: 2, day: 18} = msg.timestamp
    end

    test "handles missing thread gracefully" do
      event = build_message_event(%{
        "message" => %{
          "name" => "spaces/AAAA/messages/msg1",
          "text" => "no thread",
          "sender" => %{"name" => "users/1"}
        }
      })

      {:ok, msg} = GoogleChat.normalize(event)
      assert msg.thread_id == nil
    end

    test "handles missing user fields with empty defaults" do
      event = %{
        "type" => "MESSAGE",
        "message" => %{
          "name" => "spaces/AAAA/messages/msg1",
          "text" => "hello"
        },
        "space" => %{"name" => "spaces/AAAA"}
      }

      {:ok, msg} = GoogleChat.normalize(event)
      assert msg.user_id == ""
      assert msg.user_display_name == nil
      assert msg.user_email == nil
    end

    test "extracts attachments when present" do
      event = build_message_event(%{
        "message" => %{
          "name" => "spaces/AAAA/messages/msg1",
          "text" => "see attached",
          "sender" => %{"name" => "users/1"},
          "thread" => %{"name" => "spaces/AAAA/threads/t1"},
          "attachment" => [
            %{
              "attachmentDataRef" => %{"resourceName" => "res/123"},
              "contentType" => "image/png",
              "contentName" => "screenshot.png"
            }
          ]
        }
      })

      {:ok, msg} = GoogleChat.normalize(event)
      assert length(msg.attachments) == 1
      [att] = msg.attachments
      assert att["name"] == "res/123"
      assert att["content_type"] == "image/png"
      assert att["content_name"] == "screenshot.png"
    end

    test "returns empty attachments when none present" do
      event = build_message_event()
      {:ok, msg} = GoogleChat.normalize(event)
      assert msg.attachments == []
    end

    test "generates a unique id with gchat_ prefix" do
      event = build_message_event()
      {:ok, msg} = GoogleChat.normalize(event)
      assert String.starts_with?(msg.id, "gchat_")
      assert String.length(msg.id) > 6
    end
  end

  # ---------------------------------------------------------------
  # APP_COMMAND event
  # ---------------------------------------------------------------

  describe "normalize/1 APP_COMMAND event" do
    test "extracts slash command name from annotations" do
      event = %{
        "type" => "APP_COMMAND",
        "user" => %{"name" => "users/1", "displayName" => "Jane"},
        "space" => %{"name" => "spaces/AAAA", "type" => "DM"},
        "eventTime" => "2026-02-18T10:00:00Z",
        "message" => %{
          "name" => "spaces/AAAA/messages/cmd1",
          "text" => "/search quarterly report",
          "argumentText" => "quarterly report",
          "sender" => %{"name" => "users/1"},
          "thread" => %{"name" => "spaces/AAAA/threads/t2"},
          "annotations" => [
            %{
              "type" => "SLASH_COMMAND",
              "slashCommand" => %{"commandName" => "/search"}
            }
          ]
        }
      }

      {:ok, msg} = GoogleChat.normalize(event)

      assert msg.slash_command == "/search"
      assert msg.content == "quarterly report"
      assert msg.argument_text == "quarterly report"
      assert msg.metadata["event_type"] == "APP_COMMAND"
    end

    test "returns nil slash_command when no annotations present" do
      event = %{
        "type" => "APP_COMMAND",
        "user" => %{"name" => "users/1"},
        "space" => %{"name" => "spaces/AAAA"},
        "message" => %{
          "name" => "spaces/AAAA/messages/cmd1",
          "text" => "/help",
          "sender" => %{"name" => "users/1"},
          "thread" => %{"name" => "spaces/AAAA/threads/t2"}
        }
      }

      {:ok, msg} = GoogleChat.normalize(event)
      assert msg.slash_command == nil
    end

    test "returns nil slash_command when annotations lack SLASH_COMMAND type" do
      event = %{
        "type" => "APP_COMMAND",
        "user" => %{"name" => "users/1"},
        "space" => %{"name" => "spaces/AAAA"},
        "message" => %{
          "name" => "spaces/AAAA/messages/cmd1",
          "text" => "something",
          "sender" => %{"name" => "users/1"},
          "thread" => %{"name" => "spaces/AAAA/threads/t2"},
          "annotations" => [
            %{"type" => "USER_MENTION", "userMention" => %{"user" => %{"name" => "users/2"}}}
          ]
        }
      }

      {:ok, msg} = GoogleChat.normalize(event)
      assert msg.slash_command == nil
    end
  end

  # ---------------------------------------------------------------
  # ADDED_TO_SPACE event
  # ---------------------------------------------------------------

  describe "normalize/1 ADDED_TO_SPACE event" do
    test "returns a message with channel :google_chat and empty content" do
      event = %{
        "type" => "ADDED_TO_SPACE",
        "user" => %{"name" => "users/99", "displayName" => "Admin", "email" => "admin@co.com"},
        "space" => %{"name" => "spaces/BBBB", "type" => "ROOM", "displayName" => "Project Room"},
        "eventTime" => "2026-02-18T12:00:00Z"
      }

      {:ok, msg} = GoogleChat.normalize(event)

      assert msg.channel == :google_chat
      assert msg.content == ""
      assert msg.space_id == "spaces/BBBB"
      assert msg.user_id == "users/99"
      assert msg.user_display_name == "Admin"
      assert msg.user_email == "admin@co.com"
      assert msg.thread_id == nil
      assert msg.slash_command == nil
      assert msg.metadata["event_type"] == "ADDED_TO_SPACE"
      assert msg.metadata["space_type"] == "ROOM"
      assert msg.metadata["space_display_name"] == "Project Room"
    end
  end

  # ---------------------------------------------------------------
  # REMOVED_FROM_SPACE event
  # ---------------------------------------------------------------

  describe "normalize/1 REMOVED_FROM_SPACE event" do
    test "returns {:error, :ignored}" do
      event = %{"type" => "REMOVED_FROM_SPACE"}
      assert {:error, :ignored} = GoogleChat.normalize(event)
    end
  end

  # ---------------------------------------------------------------
  # Unknown / unhandled event types
  # ---------------------------------------------------------------

  describe "normalize/1 unknown events" do
    test "returns {:error, :ignored} for unrecognized event type" do
      event = %{"type" => "CARD_CLICKED", "data" => "something"}
      assert {:error, :ignored} = GoogleChat.normalize(event)
    end

    test "returns {:error, :ignored} for event with no type key" do
      event = %{"data" => "something"}
      assert {:error, :ignored} = GoogleChat.normalize(event)
    end

    test "returns {:error, :ignored} for empty map" do
      assert {:error, :ignored} = GoogleChat.normalize(%{})
    end
  end

  # ---------------------------------------------------------------
  # Timestamp parsing edge cases
  # ---------------------------------------------------------------

  describe "timestamp parsing" do
    test "returns nil for missing eventTime" do
      event = %{
        "type" => "MESSAGE",
        "message" => %{"name" => "m1", "text" => "hi", "sender" => %{"name" => "u1"}},
        "space" => %{"name" => "s1"}
      }

      {:ok, msg} = GoogleChat.normalize(event)
      assert msg.timestamp == nil
    end

    test "returns nil for invalid eventTime format" do
      event = %{
        "type" => "MESSAGE",
        "eventTime" => "not-a-timestamp",
        "message" => %{"name" => "m1", "text" => "hi", "sender" => %{"name" => "u1"}},
        "space" => %{"name" => "s1"}
      }

      {:ok, msg} = GoogleChat.normalize(event)
      assert msg.timestamp == nil
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp build_message_event(overrides \\ %{}) do
    base = %{
      "type" => "MESSAGE",
      "user" => %{
        "name" => "users/12345",
        "displayName" => "Jane Doe",
        "email" => "jane@example.com"
      },
      "space" => %{
        "name" => "spaces/AAAA",
        "type" => "DM"
      },
      "eventTime" => "2026-02-18T10:00:00Z",
      "message" => %{
        "name" => "spaces/AAAA/messages/msg1",
        "text" => "Hello assistant",
        "sender" => %{
          "name" => "users/12345",
          "displayName" => "Jane Doe",
          "email" => "jane@example.com"
        },
        "thread" => %{"name" => "spaces/AAAA/threads/xyz"}
      }
    }

    Map.merge(base, overrides)
  end
end

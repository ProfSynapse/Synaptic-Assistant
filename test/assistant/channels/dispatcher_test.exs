# test/assistant/channels/dispatcher_test.exs
#
# Tests for the shared Dispatcher module. Focuses on derive_conversation_id/1
# (the public helper) and dispatch/2 spawn behavior.

defmodule Assistant.Channels.DispatcherTest do
  use ExUnit.Case, async: true

  alias Assistant.Channels.Dispatcher
  alias Assistant.Channels.Message

  describe "derive_conversation_id/1" do
    test "formats as channel:space_id when no thread_id" do
      message = %Message{
        id: "test_1",
        channel: :google_chat,
        channel_message_id: "msg1",
        space_id: "spaces/AAAA",
        thread_id: nil,
        user_id: "users/1",
        content: "hello"
      }

      assert Dispatcher.derive_conversation_id(message) == "google_chat:spaces/AAAA"
    end

    test "formats as channel:space_id:thread_id when thread present" do
      message = %Message{
        id: "test_2",
        channel: :google_chat,
        channel_message_id: "msg1",
        space_id: "spaces/AAAA",
        thread_id: "spaces/AAAA/threads/xyz",
        user_id: "users/1",
        content: "hello"
      }

      assert Dispatcher.derive_conversation_id(message) ==
               "google_chat:spaces/AAAA:spaces/AAAA/threads/xyz"
    end

    test "works for Telegram channel" do
      message = %Message{
        id: "tg_1",
        channel: :telegram,
        channel_message_id: "123",
        space_id: "456789",
        thread_id: nil,
        user_id: "111",
        content: "test"
      }

      assert Dispatcher.derive_conversation_id(message) == "telegram:456789"
    end

    test "works for Slack channel with thread" do
      message = %Message{
        id: "slack_1",
        channel: :slack,
        channel_message_id: "1234567890.123456",
        space_id: "C12345",
        thread_id: "1234567890.000001",
        user_id: "U12345",
        content: "test"
      }

      assert Dispatcher.derive_conversation_id(message) ==
               "slack:C12345:1234567890.000001"
    end

    test "works for Slack channel without thread" do
      message = %Message{
        id: "slack_2",
        channel: :slack,
        channel_message_id: "1234567890.123456",
        space_id: "C12345",
        thread_id: nil,
        user_id: "U12345",
        content: "test"
      }

      assert Dispatcher.derive_conversation_id(message) == "slack:C12345"
    end
  end
end

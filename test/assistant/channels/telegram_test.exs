# test/assistant/channels/telegram_test.exs
#
# Tests for the Telegram channel adapter's normalize/1 function and capabilities.
# Follows the same pattern as google_chat_test.exs.

defmodule Assistant.Channels.TelegramTest do
  use ExUnit.Case, async: true
  @moduletag :external

  alias Assistant.Channels.Telegram
  alias Assistant.Channels.Message

  # ---------------------------------------------------------------
  # channel_name/0
  # ---------------------------------------------------------------

  describe "channel_name/0" do
    test "returns :telegram" do
      assert Telegram.channel_name() == :telegram
    end
  end

  # ---------------------------------------------------------------
  # capabilities/0
  # ---------------------------------------------------------------

  describe "capabilities/0" do
    test "returns expected capabilities" do
      caps = Telegram.capabilities()
      assert :typing in caps
      assert :markdown_formatting in caps
    end
  end

  # ---------------------------------------------------------------
  # normalize/1 — valid text messages
  # ---------------------------------------------------------------

  describe "normalize/1 text message" do
    test "extracts content, user_id, space_id from message" do
      update = build_text_update()

      assert {:ok, %Message{} = msg} = Telegram.normalize(update)

      assert msg.channel == :telegram
      assert msg.content == "Hello bot"
      assert msg.user_id == "12345"
      assert msg.space_id == "67890"
      assert msg.channel_message_id == "100"
      assert msg.slash_command == nil
      assert msg.argument_text == nil
    end

    test "extracts user display name from first_name and last_name" do
      update = build_text_update()

      {:ok, msg} = Telegram.normalize(update)
      assert msg.user_display_name == "Jane Doe"
    end

    test "handles first_name only" do
      update =
        build_text_update(%{
          "message" => %{
            "message_id" => 100,
            "text" => "hi",
            "chat" => %{"id" => 67890, "type" => "private"},
            "from" => %{"id" => 12345, "first_name" => "Jane"}
          }
        })

      {:ok, msg} = Telegram.normalize(update)
      assert msg.user_display_name == "Jane"
    end

    test "trims whitespace from content" do
      update =
        build_text_update(%{
          "message" => %{
            "message_id" => 100,
            "text" => "  spaced out  ",
            "chat" => %{"id" => 67890},
            "from" => %{"id" => 12345}
          }
        })

      {:ok, msg} = Telegram.normalize(update)
      assert msg.content == "spaced out"
    end

    test "sets metadata with chat_type" do
      update = build_text_update()

      {:ok, msg} = Telegram.normalize(update)

      assert msg.metadata["chat_type"] == "private"
    end

    test "parses unix timestamp from date" do
      update = build_text_update()

      {:ok, msg} = Telegram.normalize(update)
      assert %DateTime{} = msg.timestamp
    end

    test "generates unique id with tg_ prefix" do
      update = build_text_update()

      {:ok, msg} = Telegram.normalize(update)
      assert String.starts_with?(msg.id, "tg_")
      assert String.length(msg.id) > 3
    end

    test "maps reply_to_message to thread_id" do
      update =
        build_text_update(%{
          "message" => %{
            "message_id" => 101,
            "text" => "reply here",
            "chat" => %{"id" => 67890, "type" => "group"},
            "from" => %{"id" => 12345},
            "reply_to_message" => %{"message_id" => 50}
          }
        })

      {:ok, msg} = Telegram.normalize(update)
      assert msg.thread_id == "50"
    end

    test "thread_id is nil when no reply_to_message" do
      update = build_text_update()

      {:ok, msg} = Telegram.normalize(update)
      assert msg.thread_id == nil
    end

    test "user_email is always nil (Telegram does not provide email)" do
      update = build_text_update()

      {:ok, msg} = Telegram.normalize(update)
      assert msg.user_email == nil
    end

    test "attachments are always empty (text-only adapter)" do
      update = build_text_update()

      {:ok, msg} = Telegram.normalize(update)
      assert msg.attachments == []
    end
  end

  # ---------------------------------------------------------------
  # normalize/1 — bot commands
  # ---------------------------------------------------------------

  describe "normalize/1 bot commands" do
    test "extracts /search command with arguments" do
      update =
        build_text_update(%{
          "message" => %{
            "message_id" => 200,
            "text" => "/search quarterly report",
            "chat" => %{"id" => 67890},
            "from" => %{"id" => 12345}
          }
        })

      {:ok, msg} = Telegram.normalize(update)

      assert msg.slash_command == "/search"
      assert msg.content == "quarterly report"
      assert msg.argument_text == "quarterly report"
    end

    test "extracts /help command with bot mention" do
      update =
        build_text_update(%{
          "message" => %{
            "message_id" => 201,
            "text" => "/help@mybot",
            "chat" => %{"id" => 67890},
            "from" => %{"id" => 12345}
          }
        })

      {:ok, msg} = Telegram.normalize(update)

      assert msg.slash_command == "/help"
      assert msg.content == ""
    end

    test "extracts command with @mention and arguments" do
      update =
        build_text_update(%{
          "message" => %{
            "message_id" => 202,
            "text" => "/search@mybot quarterly report",
            "chat" => %{"id" => 67890},
            "from" => %{"id" => 12345}
          }
        })

      {:ok, msg} = Telegram.normalize(update)

      assert msg.slash_command == "/search"
      assert msg.content == "quarterly report"
      assert msg.argument_text == "quarterly report"
    end

    test "plain text has nil slash_command" do
      update = build_text_update()

      {:ok, msg} = Telegram.normalize(update)
      assert msg.slash_command == nil
    end
  end

  # ---------------------------------------------------------------
  # normalize/1 — ignored updates
  # ---------------------------------------------------------------

  describe "normalize/1 ignored updates" do
    test "ignores edited_message" do
      update = %{"edited_message" => %{"text" => "edited"}}
      assert {:error, :ignored} = Telegram.normalize(update)
    end

    test "ignores channel_post" do
      update = %{"channel_post" => %{"text" => "channel broadcast"}}
      assert {:error, :ignored} = Telegram.normalize(update)
    end

    test "ignores callback_query" do
      update = %{"callback_query" => %{"data" => "button_click"}}
      assert {:error, :ignored} = Telegram.normalize(update)
    end

    test "ignores message without text (e.g., photo-only)" do
      update = %{
        "message" => %{
          "message_id" => 300,
          "photo" => [%{"file_id" => "abc"}],
          "chat" => %{"id" => 67890},
          "from" => %{"id" => 12345}
        }
      }

      assert {:error, :ignored} = Telegram.normalize(update)
    end

    test "ignores empty map" do
      assert {:error, :ignored} = Telegram.normalize(%{})
    end

    test "ignores update with nil message" do
      assert {:error, :ignored} = Telegram.normalize(%{"message" => nil})
    end
  end

  # ---------------------------------------------------------------
  # normalize/1 — missing / malformed fields
  # ---------------------------------------------------------------

  describe "normalize/1 graceful degradation" do
    test "handles missing chat" do
      update = %{
        "message" => %{
          "message_id" => 400,
          "text" => "hello",
          "from" => %{"id" => 12345}
        }
      }

      {:ok, msg} = Telegram.normalize(update)
      assert msg.space_id == ""
    end

    test "handles missing from" do
      update = %{
        "message" => %{
          "message_id" => 401,
          "text" => "hello",
          "chat" => %{"id" => 67890}
        }
      }

      {:ok, msg} = Telegram.normalize(update)
      assert msg.user_id == ""
      assert msg.user_display_name == nil
    end

    test "handles missing message_id" do
      update = %{
        "message" => %{
          "text" => "hello",
          "chat" => %{"id" => 67890},
          "from" => %{"id" => 12345}
        }
      }

      {:ok, msg} = Telegram.normalize(update)
      assert msg.channel_message_id == ""
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp build_text_update(overrides \\ %{}) do
    base = %{
      "message" => %{
        "message_id" => 100,
        "text" => "Hello bot",
        "date" => 1_709_395_200,
        "chat" => %{
          "id" => 67890,
          "type" => "private"
        },
        "from" => %{
          "id" => 12345,
          "first_name" => "Jane",
          "last_name" => "Doe",
          "is_bot" => false
        }
      }
    }

    Map.merge(base, overrides)
  end
end

# test/assistant/channels/slack_test.exs
#
# Tests for the Slack channel adapter's normalize/1, send_reply/3, and capabilities.
# Follows the same pattern as google_chat_test.exs.

defmodule Assistant.Channels.SlackTest do
  use ExUnit.Case, async: true
  @moduletag :external

  alias Assistant.Channels.Slack
  alias Assistant.Channels.Message

  # ---------------------------------------------------------------
  # channel_name/0
  # ---------------------------------------------------------------

  describe "channel_name/0" do
    test "returns :slack" do
      assert Slack.channel_name() == :slack
    end
  end

  # ---------------------------------------------------------------
  # capabilities/0
  # ---------------------------------------------------------------

  describe "capabilities/0" do
    test "returns expected capabilities" do
      caps = Slack.capabilities()
      assert :typing in caps
      assert :threads in caps
      assert :rich_cards in caps
      assert :markdown_formatting in caps
    end
  end

  # ---------------------------------------------------------------
  # normalize/1 — valid message events
  # ---------------------------------------------------------------

  describe "normalize/1 message event" do
    test "extracts content, user_id, space_id from message" do
      event = build_message_event()

      assert {:ok, %Message{} = msg} = Slack.normalize(event)

      assert msg.channel == :slack
      assert msg.content == "Hello from Slack"
      # user_id and space_id are scoped with team_id when available
      assert msg.user_id == "slack:T00000:U12345"
      assert msg.space_id == "slack:T00000:C67890"
      assert msg.channel_message_id == "1234567890.123456"
    end

    test "sets metadata with event_type, team, channel_type" do
      event = build_message_event()

      {:ok, msg} = Slack.normalize(event)

      assert msg.metadata["event_type"] == "message"
      assert msg.metadata["team"] == "T00000"
      assert msg.metadata["channel_type"] == "im"
    end

    test "parses timestamp from Slack ts" do
      event = build_message_event()

      {:ok, msg} = Slack.normalize(event)
      assert %DateTime{} = msg.timestamp
    end

    test "generates unique id with slack_ prefix" do
      event = build_message_event()

      {:ok, msg} = Slack.normalize(event)
      assert String.starts_with?(msg.id, "slack_")
      assert String.length(msg.id) > 6
    end

    test "thread_id is nil when no thread_ts" do
      event = build_message_event()

      {:ok, msg} = Slack.normalize(event)
      assert msg.thread_id == nil
    end

    test "maps thread_ts to thread_id" do
      event =
        build_message_event(%{
          "thread_ts" => "1234567890.000001"
        })

      {:ok, msg} = Slack.normalize(event)
      assert msg.thread_id == "1234567890.000001"
    end

    test "trims whitespace from content" do
      event = build_message_event(%{"text" => "  spaced out  "})

      {:ok, msg} = Slack.normalize(event)
      assert msg.content == "spaced out"
    end

    test "user_display_name is nil (not provided by event)" do
      event = build_message_event()

      {:ok, msg} = Slack.normalize(event)
      assert msg.user_display_name == nil
    end

    test "user_email is nil (not provided by event)" do
      event = build_message_event()

      {:ok, msg} = Slack.normalize(event)
      assert msg.user_email == nil
    end

    test "attachments are always empty" do
      event = build_message_event()

      {:ok, msg} = Slack.normalize(event)
      assert msg.attachments == []
    end

    test "slash_command and argument_text are nil" do
      event = build_message_event()

      {:ok, msg} = Slack.normalize(event)
      assert msg.slash_command == nil
      assert msg.argument_text == nil
    end
  end

  # ---------------------------------------------------------------
  # normalize/1 — app_mention events
  # ---------------------------------------------------------------

  describe "normalize/1 app_mention event" do
    test "normalizes app_mention and strips bot mention from text" do
      event = %{
        "type" => "app_mention",
        "text" => "<@U_BOT> what is the status?",
        "user" => "U99999",
        "channel" => "C11111",
        "ts" => "1234567890.222222",
        "team" => "T00000"
      }

      assert {:ok, %Message{} = msg} = Slack.normalize(event)

      assert msg.channel == :slack
      # Bot mention is stripped from app_mention events
      assert msg.content == "what is the status?"
      assert msg.user_id == "slack:T00000:U99999"
      assert msg.space_id == "slack:T00000:C11111"
      assert msg.metadata["event_type"] == "app_mention"
    end

    test "strips bot mention with various ID formats" do
      event = %{
        "type" => "app_mention",
        "text" => "<@U0123ABCDEF> run report",
        "user" => "U99999",
        "channel" => "C11111",
        "ts" => "1234567890.222222",
        "team" => "T00000"
      }

      {:ok, msg} = Slack.normalize(event)
      assert msg.content == "run report"
    end

    test "does not strip mention from regular messages" do
      event = build_message_event(%{"text" => "<@U_BOT> hello"})

      {:ok, msg} = Slack.normalize(event)
      assert msg.content == "<@U_BOT> hello"
    end
  end

  # ---------------------------------------------------------------
  # normalize/1 — ignored events
  # ---------------------------------------------------------------

  describe "normalize/1 ignored events" do
    test "ignores message with subtype" do
      event = %{
        "type" => "message",
        "subtype" => "bot_message",
        "text" => "I am a bot",
        "channel" => "C12345"
      }

      assert {:error, :ignored} = Slack.normalize(event)
    end

    test "ignores message with message_changed subtype" do
      event = %{
        "type" => "message",
        "subtype" => "message_changed",
        "channel" => "C12345"
      }

      assert {:error, :ignored} = Slack.normalize(event)
    end

    test "ignores message with message_deleted subtype" do
      event = %{
        "type" => "message",
        "subtype" => "message_deleted",
        "channel" => "C12345"
      }

      assert {:error, :ignored} = Slack.normalize(event)
    end

    test "ignores app_mention with subtype" do
      event = %{
        "type" => "app_mention",
        "subtype" => "bot_message",
        "text" => "bot mention",
        "channel" => "C12345"
      }

      assert {:error, :ignored} = Slack.normalize(event)
    end

    test "ignores message with bot_id (echo prevention)" do
      event = %{
        "type" => "message",
        "bot_id" => "B12345",
        "text" => "bot echo",
        "channel" => "C12345",
        "user" => "U12345"
      }

      assert {:error, :ignored} = Slack.normalize(event)
    end

    test "ignores app_mention with bot_id" do
      event = %{
        "type" => "app_mention",
        "bot_id" => "B12345",
        "text" => "bot mention echo",
        "channel" => "C12345"
      }

      assert {:error, :ignored} = Slack.normalize(event)
    end

    test "ignores unknown event types" do
      event = %{"type" => "reaction_added", "reaction" => "thumbsup"}
      assert {:error, :ignored} = Slack.normalize(event)
    end

    test "ignores empty map" do
      assert {:error, :ignored} = Slack.normalize(%{})
    end

    test "ignores event with no type" do
      event = %{"text" => "orphan text", "channel" => "C12345"}
      assert {:error, :ignored} = Slack.normalize(event)
    end

    test "ignores message with no text" do
      event = %{
        "type" => "message",
        "user" => "U12345",
        "channel" => "C12345",
        "ts" => "1234567890.123456"
      }

      assert {:error, :ignored} = Slack.normalize(event)
    end
  end

  # ---------------------------------------------------------------
  # normalize/1 — graceful degradation
  # ---------------------------------------------------------------

  describe "normalize/1 graceful degradation" do
    test "handles missing channel field" do
      event = %{
        "type" => "message",
        "text" => "hello",
        "user" => "U12345",
        "ts" => "1234567890.123456"
      }

      {:ok, msg} = Slack.normalize(event)
      # No team_id available, so falls back to unscoped empty string
      assert msg.space_id == ""
    end

    test "handles missing user field" do
      event = %{
        "type" => "message",
        "text" => "hello",
        "channel" => "C12345",
        "ts" => "1234567890.123456"
      }

      {:ok, msg} = Slack.normalize(event)
      # No team_id available, so falls back to unscoped empty string
      assert msg.user_id == ""
    end

    test "handles missing team_id (no scoping)" do
      event = %{
        "type" => "message",
        "text" => "hello",
        "user" => "U12345",
        "channel" => "C67890",
        "ts" => "1234567890.123456"
      }

      {:ok, msg} = Slack.normalize(event)
      # Without team from either _team_id or team field, IDs are unscoped
      assert msg.user_id == "U12345"
      assert msg.space_id == "C67890"
    end

    test "scopes IDs using _team_id from controller envelope" do
      event = %{
        "type" => "message",
        "text" => "hello",
        "user" => "U12345",
        "channel" => "C67890",
        "ts" => "1234567890.123456",
        "_team_id" => "T99999"
      }

      {:ok, msg} = Slack.normalize(event)
      assert msg.user_id == "slack:T99999:U12345"
      assert msg.space_id == "slack:T99999:C67890"
    end

    test "handles missing ts field" do
      event = %{
        "type" => "message",
        "text" => "hello",
        "channel" => "C12345",
        "user" => "U12345"
      }

      {:ok, msg} = Slack.normalize(event)
      assert msg.channel_message_id == ""
      assert msg.timestamp == nil
    end
  end

  # ---------------------------------------------------------------
  # Timestamp parsing edge cases
  # ---------------------------------------------------------------

  describe "timestamp parsing" do
    test "parses valid Slack ts format" do
      event = build_message_event(%{"ts" => "1709395200.123456"})

      {:ok, msg} = Slack.normalize(event)
      assert %DateTime{year: 2024, month: 3, day: 2} = msg.timestamp
    end

    test "returns nil for nil ts" do
      event = %{
        "type" => "message",
        "text" => "hi",
        "user" => "U1",
        "channel" => "C1",
        "ts" => nil
      }

      # ts is nil but text is present — should still normalize
      {:ok, msg} = Slack.normalize(event)
      assert msg.timestamp == nil
    end
  end

  # ---------------------------------------------------------------
  # send_reply/3
  # ---------------------------------------------------------------

  describe "send_reply/3" do
    test "returns error when no bot token configured" do
      prev = Application.get_env(:assistant, :slack_bot_token)
      Application.delete_env(:assistant, :slack_bot_token)

      on_exit(fn ->
        if prev, do: Application.put_env(:assistant, :slack_bot_token, prev)
      end)

      assert {:error, :bot_token_not_configured} =
               Slack.send_reply("C12345", "hello", [])
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp build_message_event(overrides \\ %{}) do
    base = %{
      "type" => "message",
      "text" => "Hello from Slack",
      "user" => "U12345",
      "channel" => "C67890",
      "ts" => "1234567890.123456",
      "team" => "T00000",
      "channel_type" => "im"
    }

    Map.merge(base, overrides)
  end
end

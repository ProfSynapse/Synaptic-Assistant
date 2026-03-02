# test/assistant/channels/discord_test.exs
#
# Tests for the Discord channel adapter's normalize/1 function and capabilities.
# Follows the same pattern as telegram_test.exs.

defmodule Assistant.Channels.DiscordTest do
  use ExUnit.Case, async: true

  alias Assistant.Channels.Discord
  alias Assistant.Channels.Message

  # ---------------------------------------------------------------
  # channel_name/0
  # ---------------------------------------------------------------

  describe "channel_name/0" do
    test "returns :discord" do
      assert Discord.channel_name() == :discord
    end
  end

  # ---------------------------------------------------------------
  # capabilities/0
  # ---------------------------------------------------------------

  describe "capabilities/0" do
    test "returns expected capabilities" do
      caps = Discord.capabilities()
      assert :typing in caps
      assert :threads in caps
      assert :rich_cards in caps
      assert :markdown_formatting in caps
    end
  end

  # ---------------------------------------------------------------
  # normalize/1 — APPLICATION_COMMAND (slash commands)
  # ---------------------------------------------------------------

  describe "normalize/1 slash command" do
    test "extracts command name, user, guild, channel from interaction" do
      interaction = build_slash_command()

      assert {:ok, %Message{} = msg} = Discord.normalize(interaction)

      assert msg.channel == :discord
      assert msg.slash_command == "/ask"
      assert msg.content == "what is the weather"
      assert msg.argument_text == "what is the weather"
      assert msg.space_id == "discord:111222333:444555666"
      assert msg.user_id == "discord:111222333:777888999"
    end

    test "sets channel_message_id from interaction id" do
      interaction = build_slash_command()

      {:ok, msg} = Discord.normalize(interaction)
      assert msg.channel_message_id == "1234567890123456789"
    end

    test "extracts display name from member nick" do
      interaction = build_slash_command()

      {:ok, msg} = Discord.normalize(interaction)
      assert msg.user_display_name == "TestNick"
    end

    test "falls back to username when no nick" do
      interaction =
        build_slash_command(%{
          "member" => %{
            "user" => %{
              "id" => "777888999",
              "username" => "testuser",
              "global_name" => "Test User",
              "bot" => false
            }
          }
        })

      {:ok, msg} = Discord.normalize(interaction)
      assert msg.user_display_name == "Test User"
    end

    test "handles command with no options" do
      interaction =
        build_slash_command(%{
          "data" => %{
            "id" => "cmd123",
            "name" => "help"
          }
        })

      {:ok, msg} = Discord.normalize(interaction)
      assert msg.slash_command == "/help"
      assert msg.content == ""
      assert msg.argument_text == nil
    end

    test "handles command with multiple options" do
      interaction =
        build_slash_command(%{
          "data" => %{
            "id" => "cmd123",
            "name" => "search",
            "options" => [
              %{"name" => "query", "type" => 3, "value" => "quarterly report"},
              %{"name" => "limit", "type" => 4, "value" => 10}
            ]
          }
        })

      {:ok, msg} = Discord.normalize(interaction)
      assert msg.slash_command == "/search"
      assert msg.content == "quarterly report 10"
    end

    test "user_email is always nil (Discord does not provide email)" do
      interaction = build_slash_command()

      {:ok, msg} = Discord.normalize(interaction)
      assert msg.user_email == nil
    end

    test "attachments are always empty" do
      interaction = build_slash_command()

      {:ok, msg} = Discord.normalize(interaction)
      assert msg.attachments == []
    end

    test "generates unique id with discord_ prefix" do
      interaction = build_slash_command()

      {:ok, msg} = Discord.normalize(interaction)
      assert String.starts_with?(msg.id, "discord_")
      assert String.length(msg.id) > 8
    end

    test "sets metadata with interaction details" do
      interaction = build_slash_command()

      {:ok, msg} = Discord.normalize(interaction)
      assert msg.metadata["interaction_type"] == 2
      assert msg.metadata["guild_id"] == "111222333"
      assert msg.metadata["channel_id"] == "444555666"
      assert msg.metadata["command_name"] == "ask"
    end

    test "parses timestamp from snowflake ID" do
      interaction = build_slash_command()

      {:ok, msg} = Discord.normalize(interaction)
      # Snowflake should produce a valid DateTime
      assert %DateTime{} = msg.timestamp
    end
  end

  # ---------------------------------------------------------------
  # normalize/1 — bot user filtering
  # ---------------------------------------------------------------

  describe "normalize/1 bot filtering" do
    test "ignores interactions from bot users" do
      interaction =
        build_slash_command(%{
          "member" => %{
            "nick" => "BotNick",
            "user" => %{
              "id" => "777888999",
              "username" => "botuser",
              "bot" => true
            }
          }
        })

      assert {:error, :ignored} = Discord.normalize(interaction)
    end
  end

  # ---------------------------------------------------------------
  # normalize/1 — ignored interaction types
  # ---------------------------------------------------------------

  describe "normalize/1 ignored interactions" do
    test "ignores PING (type 1) — handled by controller" do
      assert {:error, :ignored} = Discord.normalize(%{"type" => 1})
    end

    test "ignores MESSAGE_COMPONENT (type 3)" do
      assert {:error, :ignored} = Discord.normalize(%{"type" => 3, "data" => %{}})
    end

    test "ignores AUTOCOMPLETE (type 5)" do
      assert {:error, :ignored} = Discord.normalize(%{"type" => 5, "data" => %{}})
    end

    test "ignores empty map" do
      assert {:error, :ignored} = Discord.normalize(%{})
    end

    test "ignores nil type" do
      assert {:error, :ignored} = Discord.normalize(%{"type" => nil})
    end
  end

  # ---------------------------------------------------------------
  # normalize/1 — graceful degradation
  # ---------------------------------------------------------------

  describe "normalize/1 graceful degradation" do
    test "handles missing guild_id (DM context)" do
      interaction =
        build_slash_command()
        |> Map.delete("guild_id")

      {:ok, msg} = Discord.normalize(interaction)
      # Missing guild_id key returns nil from map access, handled as DM context
      assert msg.space_id == "discord:dm:444555666"
    end

    test "handles nil guild_id (DM payload)" do
      interaction = build_slash_command(%{"guild_id" => nil})

      {:ok, msg} = Discord.normalize(interaction)
      # Discord DMs send guild_id: null (nil in Elixir)
      assert msg.space_id == "discord:dm:444555666"
      assert msg.user_id == "discord:dm:777888999"
    end

    test "handles missing member (DM context uses top-level user)" do
      interaction = %{
        "type" => 2,
        "id" => "1234567890123456789",
        "channel_id" => "444555666",
        "guild_id" => nil,
        "user" => %{
          "id" => "777888999",
          "username" => "dmuser",
          "bot" => false
        },
        "data" => %{
          "name" => "ask",
          "options" => [%{"name" => "query", "type" => 3, "value" => "hello"}]
        }
      }

      {:ok, msg} = Discord.normalize(interaction)
      assert msg.user_id == "discord:dm:777888999"
      assert msg.user_display_name == "dmuser"
    end

    test "handles missing data" do
      interaction = %{
        "type" => 2,
        "id" => "1234567890123456789",
        "guild_id" => "111222333",
        "channel_id" => "444555666",
        "member" => %{
          "user" => %{"id" => "777888999", "username" => "test", "bot" => false}
        }
      }

      {:ok, msg} = Discord.normalize(interaction)
      assert msg.slash_command == "/"
      assert msg.content == ""
    end
  end

  # ---------------------------------------------------------------
  # normalize/1 — snowflake validation (defense-in-depth)
  # ---------------------------------------------------------------

  describe "normalize/1 snowflake validation" do
    @tag :capture_log
    test "logs warning for non-snowflake channel_id but still processes" do
      import ExUnit.CaptureLog

      interaction =
        build_slash_command(%{
          "channel_id" => "not-a-snowflake"
        })

      log =
        capture_log(fn ->
          assert {:ok, %Message{} = msg} = Discord.normalize(interaction)
          assert msg.metadata["channel_id"] == "not-a-snowflake"
        end)

      assert log =~ "non-snowflake channel_id"
    end

    test "does not warn for valid snowflake channel_id" do
      import ExUnit.CaptureLog

      interaction = build_slash_command()

      log =
        capture_log(fn ->
          assert {:ok, %Message{}} = Discord.normalize(interaction)
        end)

      refute log =~ "non-snowflake"
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp build_slash_command(overrides \\ %{}) do
    base = %{
      "type" => 2,
      "id" => "1234567890123456789",
      "guild_id" => "111222333",
      "channel_id" => "444555666",
      "member" => %{
        "nick" => "TestNick",
        "user" => %{
          "id" => "777888999",
          "username" => "testuser",
          "global_name" => "Test User",
          "bot" => false
        }
      },
      "data" => %{
        "id" => "cmd123",
        "name" => "ask",
        "options" => [
          %{"name" => "query", "type" => 3, "value" => "what is the weather"}
        ]
      }
    }

    Map.merge(base, overrides)
  end
end

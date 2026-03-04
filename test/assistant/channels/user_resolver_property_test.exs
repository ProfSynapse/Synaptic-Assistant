# test/assistant/channels/user_resolver_property_test.exs — Property-based tests for UserResolver.
#
# Uses StreamData to generate random valid/invalid platform IDs and verify
# invariants hold across all generated inputs. Tests three core properties:
#   1. Valid external IDs always resolve to a user
#   2. Same (external_id, channel) always resolves to the same user_id (idempotency)
#   3. Invalid external IDs never create users
#
# Runs against the real database — each property test iteration creates/queries
# rows, so these are slower than unit tests but provide stronger guarantees.

defmodule Assistant.Channels.UserResolverPropertyTest do
  use Assistant.DataCase, async: true
  use ExUnitProperties

  alias Assistant.Channels.UserResolver
  alias Assistant.Schemas.{User, UserIdentity}

  # ---------------------------------------------------------------
  # Generators — valid platform IDs per channel
  # ---------------------------------------------------------------

  # Telegram: 1-20 digit numeric string
  defp valid_telegram_id do
    gen all(
          len <- integer(1..20),
          digits <- list_of(integer(?0..?9), length: len)
        ) do
      to_string(digits)
    end
  end

  # Slack: 2-20 uppercase alphanumeric characters
  defp valid_slack_id do
    gen all(
          len <- integer(2..20),
          chars <- list_of(one_of([integer(?A..?Z), integer(?0..?9)]), length: len)
        ) do
      to_string(chars)
    end
  end

  # Discord: 1-20 digit numeric string (same format as telegram)
  defp valid_discord_id do
    gen all(
          len <- integer(1..20),
          digits <- list_of(integer(?0..?9), length: len)
        ) do
      to_string(digits)
    end
  end

  # Google Chat: "users/" followed by 1-128 alphanumeric chars (including _, -)
  defp valid_google_chat_id do
    gen all(
          len <- integer(1..20),
          chars <-
            list_of(
              one_of([
                integer(?a..?z),
                integer(?A..?Z),
                integer(?0..?9),
                constant(?_),
                constant(?-)
              ]),
              length: len
            )
        ) do
      "users/" <> to_string(chars)
    end
  end

  # Generator that produces a {channel, valid_id} pair
  defp valid_channel_and_id do
    one_of([
      map(valid_telegram_id(), &{:telegram, &1}),
      map(valid_slack_id(), &{:slack, &1}),
      map(valid_discord_id(), &{:discord, &1}),
      map(valid_google_chat_id(), &{:google_chat, &1})
    ])
  end

  # ---------------------------------------------------------------
  # Generators — invalid platform IDs per channel
  # ---------------------------------------------------------------

  # Invalid Telegram ID: contains non-digit characters or exceeds 20 chars
  defp invalid_telegram_id do
    one_of([
      # Contains letters
      gen all(
            len <- integer(1..10),
            chars <- list_of(one_of([integer(?a..?z), integer(?A..?Z)]), length: len)
          ) do
        to_string(chars)
      end,
      # Contains special chars
      constant("123;456"),
      constant("12 34"),
      # Too long (21+ digits)
      gen all(
            len <- integer(21..30),
            digits <- list_of(integer(?0..?9), length: len)
          ) do
        to_string(digits)
      end,
      # Empty string
      constant("")
    ])
  end

  # Invalid Slack ID: lowercase, special chars, too short, or too long
  defp invalid_slack_id do
    one_of([
      # Lowercase
      gen all(
            len <- integer(2..10),
            chars <- list_of(integer(?a..?z), length: len)
          ) do
        to_string(chars)
      end,
      # Too short (1 char)
      gen all(char <- integer(?A..?Z)) do
        to_string([char])
      end,
      # Too long (21+ chars)
      gen all(
            len <- integer(21..30),
            chars <- list_of(integer(?A..?Z), length: len)
          ) do
        to_string(chars)
      end,
      # Special characters
      constant("U0!@#$"),
      # Empty string
      constant("")
    ])
  end

  # Invalid Discord ID: non-numeric
  defp invalid_discord_id do
    one_of([
      gen all(
            len <- integer(1..10),
            chars <- list_of(integer(?a..?z), length: len)
          ) do
        to_string(chars)
      end,
      constant("abc123"),
      constant("")
    ])
  end

  # Invalid Google Chat ID: missing "users/" prefix, empty suffix, special chars,
  # or exceeding 128-char suffix limit.
  defp invalid_google_chat_id do
    one_of([
      # Just digits, no prefix
      gen all(
            len <- integer(1..10),
            digits <- list_of(integer(?0..?9), length: len)
          ) do
        to_string(digits)
      end,
      # Wrong prefix
      constant("spaces/12345"),
      # No suffix after prefix
      constant("users/"),
      # Special characters in suffix
      constant("users/abc!@#"),
      # Path traversal attempt
      constant("users/../admin"),
      # Suffix too long (129+ chars)
      constant("users/" <> String.duplicate("a", 129)),
      # Empty string
      constant("")
    ])
  end

  # Generator that produces a {channel, invalid_id} pair
  defp invalid_channel_and_id do
    one_of([
      map(invalid_telegram_id(), &{:telegram, &1}),
      map(invalid_slack_id(), &{:slack, &1}),
      map(invalid_discord_id(), &{:discord, &1}),
      map(invalid_google_chat_id(), &{:google_chat, &1})
    ])
  end

  # ---------------------------------------------------------------
  # Property 1: Valid external IDs always resolve to a user
  # ---------------------------------------------------------------

  describe "property: valid IDs always resolve" do
    property "valid platform IDs always produce {:ok, %{user_id, conversation_id}}" do
      check all({channel, external_id} <- valid_channel_and_id(), max_runs: 30) do
        result = UserResolver.resolve(channel, external_id)

        assert {:ok, %{user_id: user_id, conversation_id: conv_id}} = result
        assert is_binary(user_id)
        assert is_binary(conv_id)

        # Verify the user actually exists in the DB
        assert Repo.get(User, user_id) != nil
      end
    end
  end

  # ---------------------------------------------------------------
  # Property 2: Idempotent resolution (same input → same output)
  # ---------------------------------------------------------------

  describe "property: idempotent resolution" do
    property "same (channel, external_id) always resolves to the same user_id" do
      check all({channel, external_id} <- valid_channel_and_id(), max_runs: 20) do
        {:ok, first} = UserResolver.resolve(channel, external_id)
        {:ok, second} = UserResolver.resolve(channel, external_id)

        assert first.user_id == second.user_id,
               "Expected same user_id for #{channel}:#{external_id}, " <>
                 "got #{first.user_id} and #{second.user_id}"

        assert first.conversation_id == second.conversation_id,
               "Expected same conversation_id for #{channel}:#{external_id}"
      end
    end
  end

  # ---------------------------------------------------------------
  # Property 3: Invalid external IDs never create users
  # ---------------------------------------------------------------

  describe "property: invalid IDs rejected" do
    property "invalid platform IDs return {:error, :invalid_platform_id}" do
      check all({channel, external_id} <- invalid_channel_and_id(), max_runs: 30) do
        user_count_before = Repo.aggregate(User, :count)

        result = UserResolver.resolve(channel, external_id)
        assert {:error, :invalid_platform_id} = result

        user_count_after = Repo.aggregate(User, :count)

        assert user_count_before == user_count_after,
               "User count changed from #{user_count_before} to #{user_count_after} " <>
                 "for invalid ID #{channel}:#{external_id}"
      end
    end

    property "invalid IDs never create identity rows" do
      check all({channel, external_id} <- invalid_channel_and_id(), max_runs: 20) do
        identity_count_before = Repo.aggregate(UserIdentity, :count)

        _result = UserResolver.resolve(channel, external_id)

        identity_count_after = Repo.aggregate(UserIdentity, :count)

        assert identity_count_before == identity_count_after,
               "Identity count changed for invalid ID #{channel}:#{external_id}"
      end
    end
  end

  # ---------------------------------------------------------------
  # Property 4: Channel isolation — same ID on different channels = different users
  # ---------------------------------------------------------------

  describe "property: channel isolation" do
    property "same numeric ID on different channels resolves to different users" do
      # Telegram and Discord both accept numeric IDs
      check all(numeric_id <- valid_telegram_id(), max_runs: 15) do
        {:ok, tg_result} = UserResolver.resolve(:telegram, numeric_id)
        {:ok, dc_result} = UserResolver.resolve(:discord, numeric_id)

        refute tg_result.user_id == dc_result.user_id,
               "telegram and discord should have different users for ID #{numeric_id}"
      end
    end
  end
end

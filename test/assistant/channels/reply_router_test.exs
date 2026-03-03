# test/assistant/channels/reply_router_test.exs — Tests for ReplyRouter.
#
# Coverage target: 80%+ (STANDARD — well-understood dispatch pattern).
# Tests reply/2,3 (hot path), send_to/3,4 (proactive), broadcast/2,3,
# and error handling for adapter failures.

defmodule Assistant.Channels.ReplyRouterTest do
  use Assistant.DataCase, async: true

  alias Assistant.Channels.ReplyRouter
  alias Assistant.Schemas.UserIdentity

  import Assistant.ChannelFixtures

  # ---------------------------------------------------------------
  # Mock adapter for testing (captures calls)
  # ---------------------------------------------------------------

  defmodule MockAdapter do
    @moduledoc false

    def send_reply(space_id, text, opts \\ []) do
      send(self(), {:mock_send_reply, space_id, text, opts})
      :ok
    end
  end

  defmodule FailingAdapter do
    @moduledoc false

    def send_reply(_space_id, _text, _opts \\ []) do
      {:error, :adapter_failure}
    end
  end

  # ---------------------------------------------------------------
  # P2: reply/2,3 — hot-path reply to originating channel
  # ---------------------------------------------------------------

  describe "reply/2,3 — hot path" do
    test "sends reply via the origin adapter" do
      origin = %{
        adapter: MockAdapter,
        channel: :telegram,
        space_id: "123456789",
        thread_id: nil
      }

      assert :ok = ReplyRouter.reply(origin, "Hello!")
      assert_received {:mock_send_reply, "123456789", "Hello!", []}
    end

    test "includes thread_id as thread_name in opts" do
      origin = %{
        adapter: MockAdapter,
        channel: :google_chat,
        space_id: "spaces/test123",
        thread_id: "threads/abc"
      }

      assert :ok = ReplyRouter.reply(origin, "Threaded reply")
      assert_received {:mock_send_reply, "spaces/test123", "Threaded reply", opts}
      assert Keyword.get(opts, :thread_name) == "threads/abc"
    end

    test "merges additional opts" do
      origin = %{
        adapter: MockAdapter,
        channel: :telegram,
        space_id: "123456789",
        thread_id: nil
      }

      assert :ok = ReplyRouter.reply(origin, "With opts", parse_mode: "Markdown")
      assert_received {:mock_send_reply, "123456789", "With opts", opts}
      assert Keyword.get(opts, :parse_mode) == "Markdown"
    end

    test "handles adapter failure" do
      origin = %{
        adapter: FailingAdapter,
        channel: :telegram,
        space_id: "123456789",
        thread_id: nil
      }

      assert {:error, :adapter_failure} = ReplyRouter.reply(origin, "Will fail")
    end
  end

  # ---------------------------------------------------------------
  # P2: send_to/3,4 — proactive messaging
  # ---------------------------------------------------------------

  describe "send_to/3,4 — proactive messaging" do
    test "returns {:error, :no_identity} when user has no identity on channel" do
      {user, _identity, _conversation} = user_with_conversation_fixture()

      # User only has a telegram identity, not discord
      assert {:error, :no_identity} =
               ReplyRouter.send_to(user.id, :discord, "Hello from Discord")
    end

    test "returns {:error, :unknown_channel} for unregistered channel" do
      {user, _identity, _conversation} = user_with_conversation_fixture()

      assert {:error, :unknown_channel} =
               ReplyRouter.send_to(user.id, :whatsapp, "Hello from WhatsApp")
    end
  end

  # ---------------------------------------------------------------
  # P2: broadcast/2,3
  # ---------------------------------------------------------------

  describe "broadcast/2,3" do
    test "returns empty list for user with no identities" do
      # Create user without any identities
      user = chat_user_fixture()

      # Remove any identities that might exist (from backfill etc.)
      from(ui in UserIdentity, where: ui.user_id == ^user.id) |> Repo.delete_all()

      assert ReplyRouter.broadcast(user.id, "Hello everywhere") == []
    end
  end
end

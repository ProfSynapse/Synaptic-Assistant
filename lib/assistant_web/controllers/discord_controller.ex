# lib/assistant_web/controllers/discord_controller.ex — Discord interaction webhook controller.
#
# Handles incoming Discord Interaction webhook requests. Ed25519 signature
# verification is performed by the DiscordAuth plug (applied in the router).
# This controller handles the PING handshake, normalizes slash command
# interactions, and delegates message processing to the shared Dispatcher.
#
# Discord expects specific JSON responses for interactions. PING (type 1)
# must return {"type": 1}. Slash commands can return an immediate
# acknowledgement or a deferred response.
#
# Related files:
#   - lib/assistant_web/plugs/discord_auth.ex (Ed25519 signature verification)
#   - lib/assistant/channels/discord.ex (interaction normalization + reply sending)
#   - lib/assistant/channels/dispatcher.ex (shared async dispatch logic)
#   - lib/assistant_web/router.ex (route definition)

defmodule AssistantWeb.DiscordController do
  @moduledoc """
  Webhook controller for Discord Interaction events.

  ## Flow

    1. DiscordAuth plug verifies the Ed25519 signature (returns 401 on failure)
    2. For PING (type 1): responds with `{"type": 1}` (Discord endpoint verification)
    3. For APPLICATION_COMMAND (type 2):
       a. Normalizes via `Channels.Discord`
       b. Dispatches to `Channels.Dispatcher` for async processing
       c. Returns a deferred response (type 5) so Discord doesn't timeout
    4. For unknown types: returns a deferred acknowledgement
  """

  use AssistantWeb, :controller

  alias Assistant.Channels.Dispatcher
  alias Assistant.Channels.Discord, as: DiscordAdapter

  require Logger

  # Discord Interaction Response Types
  # 1 = PONG, 4 = CHANNEL_MESSAGE_WITH_SOURCE, 5 = DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE
  @pong_response %{"type" => 1}
  @deferred_response %{"type" => 5}

  @doc """
  Handle a Discord Interaction webhook.

  The DiscordAuth plug has already verified the Ed25519 signature by this point.
  """

  # PING (type 1) — Discord endpoint verification handshake
  def interaction(conn, %{"type" => 1}) do
    Logger.info("Discord PING received, responding with PONG")
    json(conn, @pong_response)
  end

  # APPLICATION_COMMAND (type 2) — Slash commands
  def interaction(conn, %{"type" => 2} = params) do
    case DiscordAdapter.normalize(params) do
      {:ok, message} ->
        Logger.info("Discord slash command received",
          guild_id: message.metadata["guild_id"],
          channel_id: message.metadata["channel_id"],
          command: message.slash_command,
          user_id: message.user_id
        )

        Dispatcher.dispatch(DiscordAdapter, message)

        # Return deferred response — bot will follow up with the actual reply
        json(conn, @deferred_response)

      {:error, :ignored} ->
        # Bot message or unsupported interaction — acknowledge
        json(conn, @deferred_response)
    end
  end

  # All other interaction types — acknowledge to prevent Discord timeout
  def interaction(conn, _params) do
    json(conn, @deferred_response)
  end
end

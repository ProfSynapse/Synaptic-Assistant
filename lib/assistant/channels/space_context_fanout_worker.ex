# lib/assistant/channels/space_context_fanout_worker.ex — Oban worker for
# passive space context injection.
#
# When a user sends a message to the bot in a shared Google Chat Space, this
# worker fans out a read-only "space context" entry to every other user in
# that space. Each recipient gets paired system messages (question + response)
# appended to their perpetual conversation, tagged with metadata.type =
# "space_context" so the UI can display them with distinct styling.
#
# Related files:
#   - lib/assistant/channels/dispatcher.ex (enqueues this worker post-reply)
#   - lib/assistant/memory/store.ex (batch_append_messages, get_or_create_perpetual_conversation)
#   - lib/assistant/schemas/user_identity.ex (space membership lookup)
#   - lib/assistant/workspace.ex (renders space context in feed)

defmodule Assistant.Channels.SpaceContextFanoutWorker do
  @moduledoc """
  Oban worker that injects passive space context into other users' conversations.

  When a user interacts with the bot in a shared Google Chat Space, this worker
  distributes a read-only copy of the question and response to every other
  active member of that space. Messages are inserted as system messages with
  `metadata.type = "space_context"` for distinct rendering in the workspace UI.

  ## Guards

    * DM spaces are skipped (checks for both "DM" and "DIRECT_MESSAGE")
    * Max 50 recipients per fan-out to prevent overload
    * Only active members (left_at IS NULL) receive context

  ## Args

    * `"space_id"` — Google Chat space name (e.g., "spaces/ABC123")
    * `"sender_user_id"` — UUID of the user who sent the original message
    * `"sender_email"` — Email of the sender (for display)
    * `"sender_display_name"` — Display name of the sender
    * `"question"` — The original user message
    * `"response"` — The bot's response
    * `"space_type"` — Space type from GChat (e.g., "SPACE", "DM", "DIRECT_MESSAGE")
  """

  use Oban.Worker,
    queue: :space_context,
    max_attempts: 3,
    unique: [period: 30, fields: [:args], keys: [:space_id, :sender_user_id, :question]]

  import Ecto.Query

  alias Assistant.Memory.Store
  alias Assistant.Repo
  alias Assistant.Schemas.UserIdentity

  require Logger

  @max_recipients 50

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    space_id = args["space_id"]
    sender_user_id = args["sender_user_id"]
    space_type = args["space_type"]

    # Guard: skip DM spaces
    if dm_space?(space_type) do
      Logger.debug("SpaceContextFanout: skipping DM space #{space_id}")
      :ok
    else
      fan_out(args, space_id, sender_user_id)
    end
  end

  defp fan_out(args, space_id, sender_user_id) do
    # Query active members of this space, excluding the sender
    recipient_user_ids =
      from(ui in UserIdentity,
        where: ui.space_id == ^space_id,
        where: ui.channel == "google_chat",
        where: is_nil(ui.left_at),
        where: ui.user_id != ^sender_user_id,
        select: ui.user_id,
        distinct: true,
        limit: @max_recipients
      )
      |> Repo.all()

    if recipient_user_ids == [] do
      Logger.debug("SpaceContextFanout: no recipients for space #{space_id}")
      :ok
    else
      Logger.info("SpaceContextFanout: distributing to #{length(recipient_user_ids)} recipients",
        space_id: space_id,
        sender: sender_user_id
      )

      inject_context(recipient_user_ids, args)
    end
  end

  defp inject_context(recipient_user_ids, args) do
    sender_display_name = args["sender_display_name"] || "A colleague"
    question = args["question"] || ""
    response = args["response"] || ""
    space_id = args["space_id"]

    context_metadata = %{
      "type" => "space_context",
      "source" => %{
        "kind" => "space_context",
        "channel" => "google_chat",
        "space_id" => space_id,
        "sender_display_name" => sender_display_name,
        "sender_email" => args["sender_email"]
      }
    }

    # Build the paired messages: user question + assistant response
    messages = [
      %{
        role: "system",
        content: "[Space context from #{sender_display_name}] #{question}",
        metadata: Map.put(context_metadata, "sub_type", "question")
      },
      %{
        role: "system",
        content: "[Bot response] #{response}",
        metadata: Map.put(context_metadata, "sub_type", "response")
      }
    ]

    errors =
      Enum.reduce(recipient_user_ids, [], fn user_id, acc ->
        case inject_for_user(user_id, messages) do
          :ok -> acc
          {:error, reason} -> [{user_id, reason} | acc]
        end
      end)

    if errors != [] do
      Logger.warning("SpaceContextFanout: #{length(errors)} injection failures",
        space_id: space_id,
        errors: inspect(Enum.take(errors, 5))
      )
    end

    :ok
  end

  defp inject_for_user(user_id, messages) do
    case Store.get_or_create_perpetual_conversation(user_id) do
      {:ok, conversation} ->
        case Store.batch_append_messages(conversation.id, messages) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dm_space?(nil), do: false
  defp dm_space?("DM"), do: true
  defp dm_space?("DIRECT_MESSAGE"), do: true
  defp dm_space?(_), do: false
end

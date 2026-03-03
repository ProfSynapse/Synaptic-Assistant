# test/support/fixtures/channel_fixtures.ex — Test fixtures for the unified
# conversation architecture (users, identities, conversations).

defmodule Assistant.ChannelFixtures do
  @moduledoc """
  Test helpers for creating channel-related entities: users, user_identities,
  and perpetual conversations. Designed for the unified conversation architecture.
  """

  alias Assistant.Repo
  alias Assistant.Schemas.{Conversation, User, UserIdentity}

  # ---------------------------------------------------------------
  # Platform ID samples — one valid ID per channel for consistent test data
  # ---------------------------------------------------------------

  @platform_ids %{
    telegram: "123456789",
    slack: "U0ABCDEFG",
    discord: "987654321012345678",
    google_chat: "users/112233445566"
  }

  @doc "Returns a map of valid sample platform IDs keyed by channel atom."
  def platform_ids, do: @platform_ids

  @doc "Returns a valid sample platform ID for the given channel."
  def platform_id_for(channel), do: Map.fetch!(@platform_ids, channel)

  # ---------------------------------------------------------------
  # User fixtures
  # ---------------------------------------------------------------

  @doc """
  Creates a user row with a unique external_id.

  ## Options

    * `:external_id` — override the generated external_id
    * `:channel` — channel string (default: "telegram")
    * `:display_name` — optional display name
  """
  def chat_user_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    # Default external_id must be a valid platform ID for the default channel (telegram).
    # Telegram IDs are numeric, so we use the unique integer directly.
    defaults = %{
      external_id: "#{unique}",
      channel: "telegram"
    }

    attrs = Map.merge(defaults, Enum.into(attrs, %{}))

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert!()
  end

  # ---------------------------------------------------------------
  # UserIdentity fixtures
  # ---------------------------------------------------------------

  @doc """
  Creates a user_identity row linking a user to a channel + external_id.

  ## Parameters

    * `user` — the `%User{}` struct to link (must already be persisted)
    * `attrs` — override map. Defaults channel/external_id from the user's primary identity.
  """
  def user_identity_fixture(user, attrs \\ %{}) do
    defaults = %{
      user_id: user.id,
      channel: user.channel,
      external_id: user.external_id
    }

    attrs = Map.merge(defaults, Enum.into(attrs, %{}))

    %UserIdentity{}
    |> UserIdentity.changeset(attrs)
    |> Repo.insert!()
  end

  # ---------------------------------------------------------------
  # Full setup fixtures
  # ---------------------------------------------------------------

  @doc """
  Creates a user + identity + perpetual conversation in one call.
  Returns `{user, identity, conversation}`.

  ## Options

    * `:channel` — channel string (default: "telegram")
    * `:external_id` — platform user id (auto-generated if omitted)
    * `:display_name` — optional display name
  """
  def user_with_conversation_fixture(attrs \\ %{}) do
    user = chat_user_fixture(attrs)
    identity = user_identity_fixture(user, Map.take(attrs, [:display_name, :space_id]))

    now = DateTime.utc_now()

    {:ok, conversation} =
      %Conversation{}
      |> Conversation.changeset(%{
        channel: "unified",
        user_id: user.id,
        agent_type: "orchestrator",
        status: "active",
        started_at: now,
        last_active_at: now
      })
      |> Repo.insert()

    {user, identity, conversation}
  end
end

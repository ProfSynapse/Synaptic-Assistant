# lib/assistant/channels/user_resolver.ex — Resolves platform identities to DB users.
#
# When a message arrives from any channel (Telegram, Slack, etc.), this module
# resolves the platform-specific user ID to a DB user UUID and ensures a
# perpetual conversation exists. Auto-creates users on first contact.
#
# Related files:
#   - lib/assistant/schemas/user_identity.ex (identity mapping table)
#   - lib/assistant/schemas/user.ex (user table)
#   - lib/assistant/memory/store.ex (conversation creation)
#   - lib/assistant/channels/dispatcher.ex (primary consumer)

defmodule Assistant.Channels.UserResolver do
  @moduledoc """
  Resolves platform identities to database users and perpetual conversations.

  Given a channel atom and external_id (the platform-specific user identifier),
  returns the user's DB UUID and their perpetual conversation UUID. If the user
  doesn't exist, auto-creates them along with their identity row.

  ## Security

  - Platform IDs are validated against per-channel regex patterns before DB insert
  - Cross-channel identity linking is admin-only via `link_identity/4`
  - TODO: Allowlist check before auto-creation (v1 skips this)
  """

  import Ecto.Query

  alias Assistant.Repo
  alias Assistant.Memory.Store
  alias Assistant.Schemas.{User, UserIdentity}

  require Logger

  # Platform ID format validation patterns.
  # Each platform has a well-defined user ID format.
  @platform_id_patterns %{
    telegram: ~r/^\d{1,20}$/,
    slack: ~r/^[A-Z0-9]{2,20}$/,
    discord: ~r/^\d{1,20}$/,
    google_chat: ~r/^users\/\d{1,20}$/
  }

  @doc """
  Resolves a platform identity to a DB user and perpetual conversation.

  Looks up user_identities for the (channel, external_id) pair. If found,
  returns the user_id and ensures a perpetual conversation exists. If not
  found, auto-creates a new user, identity, and perpetual conversation.

  ## Parameters

    * `channel` - Channel atom (e.g., `:telegram`, `:slack`)
    * `external_id` - Platform-specific user identifier
    * `metadata` - Optional map with `:display_name`, `:space_id`, etc.

  ## Returns

    * `{:ok, %{user_id: binary(), conversation_id: binary()}}` on success
    * `{:error, :invalid_platform_id}` if external_id fails validation
    * `{:error, term()}` on DB errors
  """
  @spec resolve(atom(), String.t(), map()) ::
          {:ok, %{user_id: binary(), conversation_id: binary()}} | {:error, term()}
  def resolve(channel, external_id, metadata \\ %{}) do
    with :ok <- validate_platform_id(channel, external_id) do
      case find_identity(channel, external_id) do
        {:ok, identity} ->
          ensure_perpetual_conversation(identity.user_id)

        {:error, :not_found} ->
          create_user_and_resolve(channel, external_id, metadata)
      end
    end
  end

  @doc """
  Links an additional platform identity to an existing user.

  This is an admin-only operation for cross-channel identity linking.
  Creates a new user_identity row mapping the given (channel, external_id)
  to the specified user_id.

  ## Parameters

    * `user_id` - The DB user UUID to link to
    * `channel` - Channel atom for the new identity
    * `external_id` - Platform-specific user identifier
    * `space_id` - Optional space/workspace identifier

  ## Returns

    * `{:ok, %UserIdentity{}}` on success
    * `{:error, :invalid_platform_id}` if external_id fails validation
    * `{:error, %Ecto.Changeset{}}` on constraint violation (e.g., identity already linked)
  """
  @spec link_identity(binary(), atom(), String.t(), String.t() | nil) ::
          {:ok, UserIdentity.t()} | {:error, term()}
  def link_identity(user_id, channel, external_id, space_id \\ nil) do
    with :ok <- validate_platform_id(channel, external_id) do
      %UserIdentity{}
      |> UserIdentity.changeset(%{
        user_id: user_id,
        channel: to_string(channel),
        external_id: external_id,
        space_id: space_id
      })
      |> Repo.insert()
    end
  end

  # --- Private ---

  defp validate_platform_id(channel, external_id) do
    case Map.get(@platform_id_patterns, channel) do
      nil ->
        # Unknown channel — allow through (no pattern to validate against)
        :ok

      pattern ->
        if Regex.match?(pattern, external_id) do
          :ok
        else
          Logger.warning("Invalid platform ID format",
            channel: channel,
            external_id: external_id
          )

          {:error, :invalid_platform_id}
        end
    end
  end

  defp find_identity(channel, external_id) do
    query =
      from ui in UserIdentity,
        where: ui.channel == ^to_string(channel) and ui.external_id == ^external_id,
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      identity -> {:ok, identity}
    end
  end

  defp create_user_and_resolve(channel, external_id, metadata) do
    # TODO: Allowlist check — for v1, all users are allowed.
    # When implemented, check allowlist before creating the user and
    # return {:error, :not_allowed} if the user is not on the list.

    display_name = Map.get(metadata, :display_name) || Map.get(metadata, "display_name")
    space_id = Map.get(metadata, :space_id) || Map.get(metadata, "space_id")
    channel_str = to_string(channel)

    Repo.transaction(fn ->
      # Create user with primary identity fields
      user_attrs = %{
        external_id: external_id,
        channel: channel_str,
        display_name: display_name
      }

      case %User{} |> User.changeset(user_attrs) |> Repo.insert() do
        {:ok, user} ->
          # Create the identity row
          identity_attrs = %{
            user_id: user.id,
            channel: channel_str,
            external_id: external_id,
            space_id: space_id,
            display_name: display_name
          }

          case %UserIdentity{} |> UserIdentity.changeset(identity_attrs) |> Repo.insert() do
            {:ok, _identity} ->
              user.id

            {:error, changeset} ->
              Repo.rollback(changeset)
          end

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, user_id} ->
        ensure_perpetual_conversation(user_id)

      {:error, reason} ->
        # Race condition: another process may have created this user.
        # Try to find the identity that was just created.
        case find_identity(channel, external_id) do
          {:ok, identity} ->
            ensure_perpetual_conversation(identity.user_id)

          {:error, :not_found} ->
            {:error, reason}
        end
    end
  end

  defp ensure_perpetual_conversation(user_id) do
    case Store.get_or_create_perpetual_conversation(user_id) do
      {:ok, conversation} ->
        {:ok, %{user_id: user_id, conversation_id: conversation.id}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

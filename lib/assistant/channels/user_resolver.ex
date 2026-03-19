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
  - User allowlist: configurable via `Application.get_env(:assistant, :user_allowlist, :open)`.
    When `:open` (default), all users are auto-created. When a list of external IDs,
    only listed users are allowed through.
  """

  import Ecto.Query

  alias Assistant.Repo
  alias Assistant.Accounts.SettingsUser
  alias Assistant.Billing
  alias Assistant.Memory.Store
  alias Assistant.Schemas.{User, UserIdentity}

  require Logger

  # Platform ID format validation patterns.
  # Each platform has a well-defined user ID format.
  @platform_id_patterns %{
    telegram: ~r/^\d{1,20}$/,
    slack: ~r/^[A-Z0-9]{2,20}$/,
    discord: ~r/^\d{1,20}$/,
    google_chat: ~r/^users\/[a-zA-Z0-9_\-]{1,128}$/
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
    space_id = Map.get(metadata, :space_id) || Map.get(metadata, "space_id")

    with :ok <- validate_platform_id(channel, external_id) do
      case find_identity(channel, external_id, space_id) do
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

  defp find_identity(channel, external_id, space_id) do
    channel_str = to_string(channel)

    query =
      from ui in UserIdentity,
        where: ui.channel == ^channel_str and ui.external_id == ^external_id

    exact_query =
      if space_id do
        from ui in query, where: ui.space_id == ^space_id
      else
        from ui in query, where: is_nil(ui.space_id)
      end

    case Repo.one(exact_query) do
      nil when space_id != nil ->
        # Fallback: look for a backfilled row with NULL space_id and self-heal it.
        # This handles the migration case where existing identities have space_id = NULL
        # but dispatchers now pass real space_id values.
        fallback_query = from ui in query, where: is_nil(ui.space_id)

        case Repo.one(fallback_query) do
          nil ->
            {:error, :not_found}

          identity ->
            Logger.info("Backfilling space_id for identity #{identity.id}: #{space_id}")

            identity
            |> Ecto.Changeset.change(%{space_id: space_id})
            |> Repo.update!()

            {:ok, %{identity | space_id: space_id}}
        end

      nil ->
        {:error, :not_found}

      identity ->
        {:ok, identity}
    end
  end

  defp create_user_and_resolve(channel, external_id, metadata) do
    if not is_allowed?(channel, external_id) do
      Logger.warning("User not on allowlist, rejecting auto-creation",
        channel: channel,
        external_id: external_id
      )

      {:error, :not_allowed}
    else
      do_create_user_and_resolve(channel, external_id, metadata)
    end
  end

  defp do_create_user_and_resolve(channel, external_id, metadata) do
    display_name = Map.get(metadata, :display_name) || Map.get(metadata, "display_name")
    space_id = Map.get(metadata, :space_id) || Map.get(metadata, "space_id")
    channel_str = to_string(channel)
    user_email = extract_user_email(metadata)

    case find_linked_user_id_by_email(user_email) do
      {:real, linked_user_id} ->
        # Found a real (non-pseudo) user with this email — link identity to them
        Logger.info("Linking inbound channel identity to existing user by email",
          channel: channel,
          external_id: external_id,
          user_id: linked_user_id
        )

        link_identity_and_resolve(
          linked_user_id,
          channel_str,
          external_id,
          space_id,
          display_name,
          channel
        )

      {:pseudo, pseudo_user_id, settings_user_id} ->
        # Found a pseudo-user whose settings_user has this email — upgrade
        Logger.info("Upgrading pseudo-user: creating real user and migrating",
          channel: channel,
          external_id: external_id,
          pseudo_user_id: pseudo_user_id
        )

        create_user_upgrade_pseudo_and_resolve(
          channel,
          channel_str,
          external_id,
          space_id,
          display_name,
          user_email,
          pseudo_user_id,
          settings_user_id
        )

      :not_found ->
        create_new_user_and_resolve(
          channel,
          channel_str,
          external_id,
          space_id,
          display_name,
          user_email
        )
    end
  end

  defp link_identity_and_resolve(
         user_id,
         channel_str,
         external_id,
         space_id,
         display_name,
         channel
       ) do
    identity_attrs = %{
      user_id: user_id,
      channel: channel_str,
      external_id: external_id,
      space_id: space_id,
      display_name: display_name
    }

    case %UserIdentity{} |> UserIdentity.changeset(identity_attrs) |> Repo.insert() do
      {:ok, _identity} ->
        ensure_perpetual_conversation(user_id)

      {:error, reason} ->
        resolve_after_insert_error(channel, external_id, space_id, reason)
    end
  end

  # Create a real user, migrate pseudo-user's data, then link identity
  defp create_user_upgrade_pseudo_and_resolve(
         channel,
         channel_str,
         external_id,
         space_id,
         display_name,
         user_email,
         pseudo_user_id,
         settings_user_id
       ) do
    case Repo.transaction(fn ->
           # Create the real user
           user_attrs = %{
             external_id: external_id,
             channel: channel_str,
             display_name: display_name,
             email: user_email
           }

           case %User{} |> User.changeset(user_attrs) |> Repo.insert() do
             {:ok, user} ->
               Logger.info("Created real user for pseudo-user upgrade",
                 user_id: user.id,
                 pseudo_user_id: pseudo_user_id
               )

               # Upgrade: re-link settings_user, migrate conversations
               do_upgrade_pseudo_user(pseudo_user_id, user.id, settings_user_id)

               # Create the identity row
               identity_attrs = %{
                 user_id: user.id,
                 channel: channel_str,
                 external_id: external_id,
                 space_id: space_id,
                 display_name: display_name
               }

               case %UserIdentity{} |> UserIdentity.changeset(identity_attrs) |> Repo.insert() do
                 {:ok, _identity} -> user.id
                 {:error, changeset} -> Repo.rollback(changeset)
               end

             {:error, changeset} ->
               Repo.rollback(changeset)
           end
         end) do
      {:ok, user_id} ->
        ensure_perpetual_conversation(user_id)

      {:error, reason} ->
        resolve_after_insert_error(channel, external_id, space_id, reason)
    end
  end

  defp create_new_user_and_resolve(
         channel,
         channel_str,
         external_id,
         space_id,
         display_name,
         user_email
       ) do
    Repo.transaction(fn ->
      # Create user with primary identity fields + email
      user_attrs =
        %{
          external_id: external_id,
          channel: channel_str,
          display_name: display_name
        }
        |> maybe_put_email(user_email)

      case %User{} |> User.changeset(user_attrs) |> Repo.insert() do
        {:ok, user} ->
          Logger.info("Auto-created user",
            user_id: user.id,
            external_id: external_id,
            channel: channel_str,
            email: user_email
          )

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
        resolve_after_insert_error(channel, external_id, space_id, reason)
    end
  end

  defp maybe_put_email(attrs, nil), do: attrs

  defp maybe_put_email(attrs, email) when is_binary(email) do
    normalized = normalize_email(email)
    if normalized, do: Map.put(attrs, :email, normalized), else: attrs
  end

  defp resolve_after_insert_error(channel, external_id, space_id, reason) do
    # Race condition: another process may have created this identity.
    # Try to find the identity that was just created.
    case find_identity(channel, external_id, space_id) do
      {:ok, identity} ->
        ensure_perpetual_conversation(identity.user_id)

      {:error, :not_found} ->
        {:error, reason}
    end
  end

  # Searches for a user by email. Returns:
  #   {:real, user_id}                     — non-pseudo user with this email
  #   {:pseudo, pseudo_user_id, su_id}     — pseudo-user whose settings_user has this email
  #   :not_found                           — no match
  defp find_linked_user_id_by_email(email) when is_binary(email) do
    normalized_email = normalize_email(email)

    if is_binary(normalized_email) do
      # First: check users.email directly for a real (non-pseudo) user
      real_user_query =
        from u in User,
          where: fragment("lower(?)", u.email) == ^normalized_email,
          where: u.channel != "settings" or is_nil(u.channel),
          select: u.id,
          limit: 1

      case Repo.one(real_user_query) do
        user_id when is_binary(user_id) ->
          {:real, user_id}

        nil ->
          # Second: check settings_users for a linked pseudo-user
          pseudo_query =
            from su in SettingsUser,
              join: u in User,
              on: u.id == su.user_id,
              where: fragment("lower(?)", su.email) == ^normalized_email,
              where: not is_nil(su.user_id),
              where: u.channel == "settings",
              select: {su.user_id, su.id},
              limit: 1

          case Repo.one(pseudo_query) do
            {pseudo_user_id, settings_user_id} ->
              {:pseudo, pseudo_user_id, settings_user_id}

            nil ->
              # Third: check settings_users that have a user_id pointing to a real user
              # (handles case where settings_user email matches but user.email wasn't set yet)
              settings_real_query =
                from su in SettingsUser,
                  join: u in User,
                  on: u.id == su.user_id,
                  where: fragment("lower(?)", su.email) == ^normalized_email,
                  where: not is_nil(su.user_id),
                  where: u.channel != "settings" or is_nil(u.channel),
                  select: su.user_id,
                  limit: 1

              case Repo.one(settings_real_query) do
                user_id when is_binary(user_id) -> {:real, user_id}
                nil -> :not_found
              end
          end
      end
    else
      :not_found
    end
  end

  defp find_linked_user_id_by_email(_), do: :not_found

  defp extract_user_email(metadata) when is_map(metadata) do
    Map.get(metadata, :user_email) ||
      Map.get(metadata, "user_email") ||
      Map.get(metadata, :email) ||
      Map.get(metadata, "email")
  end

  defp extract_user_email(_), do: nil

  defp normalize_email(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_email(_), do: nil

  @doc """
  Upgrades a pseudo-user by migrating all data to a real user.

  Atomically re-links settings_user, migrates conversations, connected_drives,
  and oauth_tokens from the pseudo-user to the real user. Archives the
  pseudo-user by setting channel to "settings:archived".

  ## Parameters

    * `pseudo_user_id` - The pseudo-user UUID to migrate from
    * `real_user_id` - The real user UUID to migrate to

  ## Returns

    * `{:ok, real_user_id}` on success
    * `{:error, term()}` on failure
  """
  @spec upgrade_pseudo_user(binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def upgrade_pseudo_user(pseudo_user_id, real_user_id) do
    Repo.transaction(fn ->
      # Re-link all settings_users pointing to pseudo-user
      from(su in SettingsUser,
        where: su.user_id == ^pseudo_user_id
      )
      |> Repo.update_all(set: [user_id: real_user_id])

      Billing.sync_linked_user_billing_account_by_user_id(real_user_id)

      do_upgrade_pseudo_user(pseudo_user_id, real_user_id, nil)
      real_user_id
    end)
  end

  # Internal: performs the data migration from pseudo-user to real user.
  # Called both from upgrade_pseudo_user/2 (public) and within
  # create_user_upgrade_pseudo_and_resolve (during identity resolution).
  defp do_upgrade_pseudo_user(pseudo_user_id, real_user_id, settings_user_id) do
    import Ecto.Query

    # Re-link settings_user if a specific one was identified
    if settings_user_id do
      from(su in SettingsUser, where: su.id == ^settings_user_id)
      |> Repo.update_all(set: [user_id: real_user_id])
    end

    # Migrate conversations (re-parent to real user)
    {conv_count, _} =
      from(c in Assistant.Schemas.Conversation,
        where: c.user_id == ^pseudo_user_id
      )
      |> Repo.update_all(set: [user_id: real_user_id])

    # Migrate connected drives
    {drives_count, _} =
      from(cd in Assistant.Schemas.ConnectedDrive,
        where: cd.user_id == ^pseudo_user_id
      )
      |> Repo.update_all(set: [user_id: real_user_id])

    # Migrate oauth tokens
    {tokens_count, _} =
      from(ot in Assistant.Schemas.OAuthToken,
        where: ot.user_id == ^pseudo_user_id
      )
      |> Repo.update_all(set: [user_id: real_user_id])

    # Archive the pseudo-user (don't delete — preserves audit trail)
    case Repo.get(User, pseudo_user_id) do
      nil ->
        :ok

      pseudo_user ->
        pseudo_user
        |> Ecto.Changeset.change(%{channel: "settings:archived"})
        |> Repo.update()
    end

    Logger.info("Pseudo-user upgrade complete",
      pseudo_user_id: pseudo_user_id,
      real_user_id: real_user_id,
      conversations_migrated: conv_count,
      drives_migrated: drives_count,
      tokens_migrated: tokens_count
    )

    :ok
  end

  defp ensure_perpetual_conversation(user_id) do
    case Store.get_or_create_perpetual_conversation(user_id) do
      {:ok, conversation} ->
        {:ok, %{user_id: user_id, conversation_id: conversation.id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Checks user allowlist configuration.
  # :open (default) — all users allowed.
  # List of external IDs — only listed users allowed.
  defp is_allowed?(_channel, external_id) do
    case Application.get_env(:assistant, :user_allowlist, :open) do
      :open -> true
      allowlist when is_list(allowlist) -> external_id in allowlist
    end
  end
end

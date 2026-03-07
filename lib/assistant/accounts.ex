defmodule Assistant.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Assistant.Repo

  alias Assistant.Accounts.{
    CrossChannelBridge,
    SettingsUser,
    SettingsUserAllowlistEntry,
    SettingsUserNotifier,
    SettingsUserToken,
    Team
  }

  @managed_access_scopes [
    "chat",
    "workflows",
    "memory",
    "integrations",
    "analytics"
  ]

  def managed_access_scopes, do: @managed_access_scopes

  ## Admin and allowlist

  @doc """
  Returns `true` when the admin bootstrap flow is available.

  Bootstrap is available only until at least one admin exists.
  """
  def admin_bootstrap_available? do
    not Repo.exists?(from(su in SettingsUser, where: su.is_admin == true))
  end

  @doc """
  Claims the initial admin role for the given settings_user and creates
  a matching allowlist entry.
  """
  def bootstrap_admin_access(%SettingsUser{} = settings_user) do
    if admin_bootstrap_available?() do
      Repo.transact(fn ->
        with {:ok, _entry} <-
               upsert_settings_user_allowlist_entry(
                 %{
                   email: settings_user.email,
                   active: true,
                   is_admin: true,
                   scopes: @managed_access_scopes,
                   notes: "Bootstrap admin"
                 },
                 settings_user,
                 transaction?: false
               ),
             {:ok, synced_user} <- sync_settings_user_access_from_allowlist(settings_user),
             {:ok, super_admin} <-
               synced_user
               |> Ecto.Changeset.change(is_super_admin: true)
               |> Repo.update() do
          {:ok, super_admin}
        else
          {:error, _} = error -> error
        end
      end)
    else
      {:error, :bootstrap_closed}
    end
  end

  @doc """
  Registers a new settings_user with the given email and password, confirms
  them immediately, and claims the initial admin role — all in one transaction.

  This is the happy-path for the first-admin setup page. It bypasses the
  allowlist check (no allowlist exists yet) and email confirmation (first
  admin should be usable immediately).

  Returns `{:ok, settings_user}` or `{:error, changeset}`.
  """
  def register_and_bootstrap_admin(attrs) do
    if admin_bootstrap_available?() do
      Repo.transaction(fn ->
        with {:ok, settings_user} <- do_register_admin(attrs),
             {:ok, confirmed_user} <- do_confirm_user(settings_user),
             {:ok, admin_user} <- do_bootstrap_admin(confirmed_user) do
          admin_user
        else
          {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      changeset =
        %SettingsUser{}
        |> SettingsUser.email_changeset(attrs)
        |> Ecto.Changeset.add_error(:email, "admin setup is no longer available")

      {:error, changeset}
    end
  end

  defp do_register_admin(attrs) do
    # Compose email + password validations into one changeset for a single insert.
    # SettingsUser.password_changeset/3 accepts a changeset (cast/3 handles both).
    %SettingsUser{}
    |> SettingsUser.email_changeset(attrs)
    |> SettingsUser.password_changeset(attrs)
    |> Repo.insert()
  end

  defp do_confirm_user(settings_user) do
    settings_user
    |> SettingsUser.confirm_changeset()
    |> Repo.update()
  end

  defp do_bootstrap_admin(settings_user) do
    with {:ok, _entry} <-
           upsert_settings_user_allowlist_entry(
             %{
               email: settings_user.email,
               active: true,
               is_admin: true,
               scopes: @managed_access_scopes,
               notes: "Bootstrap admin"
             },
             settings_user,
             transaction?: false
           ),
         {:ok, synced_user} <- sync_settings_user_access_from_allowlist(settings_user),
         {:ok, super_admin} <-
           synced_user
           |> Ecto.Changeset.change(is_super_admin: true)
           |> Repo.update() do
      {:ok, super_admin}
    end
  end

  ## Teams

  @doc """
  Lists all teams.
  """
  def list_teams do
    Repo.all(from(t in Team, order_by: [asc: t.name]))
  end

  @doc """
  Gets a team by ID.
  """
  def get_team(id) when is_binary(id), do: Repo.get(Team, id)
  def get_team(_), do: nil

  @doc """
  Creates a team.
  """
  def create_team(attrs) do
    %Team{}
    |> Team.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a team.
  """
  def update_team(%Team{} = team, attrs) do
    team
    |> Team.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a team. Users in the team will have team_id set to nil.
  """
  def delete_team(%Team{} = team) do
    Repo.delete(team)
  end

  @doc """
  Returns a changeset for a team.
  """
  def change_team(%Team{} = team, attrs \\ %{}) do
    Team.changeset(team, attrs)
  end

  @doc """
  Assigns a settings_user to a team.
  """
  def assign_user_to_team(settings_user_id, team_id)
      when is_binary(settings_user_id) do
    case Repo.get(SettingsUser, settings_user_id) do
      nil -> {:error, :not_found}
      user ->
        user
        |> Ecto.Changeset.change(team_id: team_id)
        |> Repo.update()
    end
  end

  @doc """
  Lists all settings users for the admin UI.
  Super admins see all users; team admins see only users in their team.
  """
  def list_admin_settings_users(opts \\ []) do
    team_id = Keyword.get(opts, :team_id)

    query =
      from(su in SettingsUser,
        order_by: [desc: su.is_super_admin, desc: su.is_admin, asc: su.email]
      )

    query =
      if team_id do
        from(su in query, where: su.team_id == ^team_id)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Lists allowlist entries for the admin UI.
  """
  def list_settings_user_allowlist_entries do
    Repo.all(
      from(e in SettingsUserAllowlistEntry,
        order_by: [desc: e.active, asc: e.email]
      )
    )
  end

  @doc """
  Returns a changeset for an allowlist entry.
  """
  def change_settings_user_allowlist_entry(entry, attrs \\ %{}) do
    SettingsUserAllowlistEntry.changeset(entry, attrs, allowed_scopes: @managed_access_scopes)
  end

  @doc """
  Creates or updates an allowlist entry keyed by email.
  """
  def upsert_settings_user_allowlist_entry(attrs, actor \\ nil, opts \\ [])

  def upsert_settings_user_allowlist_entry(attrs, actor, opts) when is_map(attrs) do
    transaction? = Keyword.get(opts, :transaction?, true)

    fun = fn ->
      email = normalize_email_param(Map.get(attrs, :email) || Map.get(attrs, "email"))
      entry = if is_binary(email), do: Repo.get_by(SettingsUserAllowlistEntry, email: email)

      attrs =
        attrs
        |> Map.new()
        |> Map.put(:email, email)

      base = entry || %SettingsUserAllowlistEntry{}

      changeset =
        base
        |> change_settings_user_allowlist_entry(attrs)
        |> maybe_stamp_allowlist_actor(actor)

      with {:ok, saved_entry} <- Repo.insert_or_update(changeset),
           :ok <- sync_matching_settings_user_access(saved_entry.email) do
        {:ok, saved_entry}
      else
        {:error, _} = error -> error
      end
    end

    if transaction?, do: Repo.transact(fun), else: fun.()
  end

  @doc """
  Creates a new settings_user from the admin panel.

  Wraps allowlist upsert + settings_user insert in a single transaction.
  The settings_user is created with `hashed_password: nil` (magic-link-only
  until the user sets a password). Optionally sends an invite email.

  ## Options

    * `:send_invite` — When `true` and a `magic_link_url_fun` is provided,
      delivers login instructions after creation.
    * `:magic_link_url_fun` — A 1-arity function that builds the magic link URL.
  """
  def create_settings_user_from_admin(attrs, opts \\ []) do
    Repo.transact(fn ->
      email = normalize_email_param(Map.get(attrs, :email) || Map.get(attrs, "email"))

      if is_nil(email) or email == "" do
        {:error, :missing_email}
      else
        allowlist_attrs = %{
          email: email,
          full_name: Map.get(attrs, :full_name) || Map.get(attrs, "full_name"),
          active: true,
          is_admin: Map.get(attrs, :is_admin, false),
          scopes: Map.get(attrs, :access_scopes) || Map.get(attrs, "access_scopes") || [],
          notes: "Created by admin"
        }

        with {:ok, _entry} <- upsert_settings_user_allowlist_entry(allowlist_attrs, nil, transaction?: false) do
          case get_settings_user_by_email(email) do
            %SettingsUser{} = existing ->
              {:ok, existing}

            nil ->
              full_name = Map.get(attrs, :full_name) || Map.get(attrs, "full_name")

              team_id = Map.get(attrs, :team_id) || Map.get(attrs, "team_id")

              %SettingsUser{}
              |> SettingsUser.email_changeset(%{email: email}, validate_changed: false)
              |> Ecto.Changeset.change(
                hashed_password: nil,
                full_name: full_name,
                team_id: team_id,
                confirmed_at: nil
              )
              |> Repo.insert()
              |> case do
                {:ok, settings_user} ->
                  # Sync admin/scopes from allowlist
                  case sync_settings_user_access_from_allowlist(settings_user) do
                    {:ok, synced_user} ->
                      maybe_send_invite(synced_user, opts)
                      {:ok, synced_user}

                    error ->
                      error
                  end

                error ->
                  error
              end
          end
        end
      end
    end)
  end

  defp maybe_send_invite(settings_user, opts) do
    if Keyword.get(opts, :send_invite, false) do
      case Keyword.get(opts, :magic_link_url_fun) do
        fun when is_function(fun, 1) ->
          deliver_login_instructions(settings_user, fun)

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Sends a recovery magic link to the given settings user.
  """
  def admin_send_recovery_link(%SettingsUser{} = settings_user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    deliver_login_instructions(settings_user, magic_link_url_fun)
  end

  @doc """
  Clears the user's password, expires active sessions, and sends a recovery link.
  """
  def admin_force_password_reset(%SettingsUser{} = settings_user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    with {:ok, {updated_user, expired_tokens}} <-
           Ecto.Changeset.change(settings_user, hashed_password: nil)
           |> update_settings_user_and_delete_all_tokens(),
         {:ok, email} <- deliver_login_instructions(updated_user, magic_link_url_fun) do
      {:ok, updated_user, expired_tokens, email}
    end
  end

  ## Database getters

  @doc """
  Gets a settings_user by email.

  ## Examples

      iex> get_settings_user_by_email("foo@example.com")
      %SettingsUser{}

      iex> get_settings_user_by_email("unknown@example.com")
      nil

  """
  def get_settings_user_by_email(email) when is_binary(email) do
    Repo.get_by(SettingsUser, email: email)
  end

  @doc """
  Gets a settings_user by email and password.

  ## Examples

      iex> get_settings_user_by_email_and_password("foo@example.com", "correct_password")
      %SettingsUser{}

      iex> get_settings_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_settings_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    settings_user = Repo.get_by(SettingsUser, email: email)

    if SettingsUser.valid_password?(settings_user, password) do
      case maybe_sync_and_authorize_settings_user(settings_user) do
        {:ok, synced_settings_user} -> synced_settings_user
        _ -> nil
      end
    end
  end

  @doc """
  Gets a single settings_user.

  Raises `Ecto.NoResultsError` if the SettingsUser does not exist.

  ## Examples

      iex> get_settings_user!(123)
      %SettingsUser{}

      iex> get_settings_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_settings_user!(id), do: Repo.get!(SettingsUser, id)

  @doc """
  Gets a single settings_user by id.
  """
  def get_settings_user(id) when is_binary(id), do: Repo.get(SettingsUser, id)
  def get_settings_user(_), do: nil

  @doc """
  Gets a settings_user by linked chat user ID.
  """
  def get_settings_user_by_user_id(user_id) when is_binary(user_id) do
    with {:ok, cast_user_id} <- Ecto.UUID.cast(user_id) do
      Repo.get_by(SettingsUser, user_id: cast_user_id)
    else
      :error -> nil
    end
  end

  def get_settings_user_by_user_id(_), do: nil

  ## Settings user registration

  @doc """
  Registers a settings_user.

  ## Examples

      iex> register_settings_user(%{field: value})
      {:ok, %SettingsUser{}}

      iex> register_settings_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_settings_user(attrs) do
    %SettingsUser{}
    |> SettingsUser.email_changeset(attrs)
    |> maybe_validate_allowlist_registration()
    |> Repo.insert()
    |> maybe_sync_new_settings_user_access()
  end

  @doc """
  Gets or creates a settings user from Google OAuth claims and marks the account as confirmed.
  """
  def get_or_register_settings_user_from_google(attrs) when is_map(attrs) do
    with {:ok, email} <- normalize_oauth_email(Map.get(attrs, "email") || Map.get(attrs, :email)) do
      display_name = normalize_oauth_display_name(Map.get(attrs, "name") || Map.get(attrs, :name))

      if email_allowed_by_allowlist?(email) do
        case get_settings_user_by_email(email) do
          nil ->
            %SettingsUser{}
            |> SettingsUser.email_changeset(%{email: email}, validate_changed: false)
            |> Ecto.Changeset.change(
              display_name: display_name,
              confirmed_at: DateTime.utc_now(:second)
            )
            |> Repo.insert()
            |> maybe_sync_new_settings_user_access()

          %SettingsUser{} = settings_user ->
            attrs =
              %{}
              |> maybe_put_confirmed_at(settings_user)
              |> maybe_put_display_name(settings_user, display_name)

            result =
              if map_size(attrs) == 0 do
                {:ok, settings_user}
              else
                settings_user
                |> Ecto.Changeset.change(attrs)
                |> Repo.update()
              end

            case result do
              {:ok, updated_settings_user} ->
                maybe_sync_and_authorize_settings_user(updated_settings_user)

              other ->
                other
            end
        end
      else
        {:error, :not_allowed}
      end
    end
  end

  def get_or_register_settings_user_from_google(_), do: {:error, :invalid_google_claims}

  ## Settings

  @doc """
  Returns an `%Ecto.Changeset{}` for updating profile fields.
  """
  def change_settings_user_profile(settings_user, attrs \\ %{}) do
    SettingsUser.profile_changeset(settings_user, attrs)
  end

  @doc """
  Updates profile fields for a settings_user.
  """
  def update_settings_user_profile(settings_user, attrs) do
    settings_user
    |> SettingsUser.profile_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates the per-user model default overrides for a settings_user.
  """
  def update_settings_user_model_defaults(%SettingsUser{} = settings_user, defaults)
      when is_map(defaults) do
    settings_user
    |> SettingsUser.model_defaults_changeset(defaults)
    |> Repo.update()
  end

  @doc """
  Checks whether the settings_user is in sudo mode.

  The settings_user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(settings_user, minutes \\ -20)

  def sudo_mode?(%SettingsUser{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_settings_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the settings_user email.

  See `Assistant.Accounts.SettingsUser.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_settings_user_email(settings_user)
      %Ecto.Changeset{data: %SettingsUser{}}

  """
  def change_settings_user_email(settings_user, attrs \\ %{}, opts \\ []) do
    SettingsUser.email_changeset(settings_user, attrs, opts)
  end

  @doc """
  Updates the settings_user email using the given token.

  If the token matches, the settings_user email is updated and the token is deleted.
  """
  def update_settings_user_email(settings_user, token) do
    context = "change:#{settings_user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- SettingsUserToken.verify_change_email_token_query(token, context),
           %SettingsUserToken{sent_to: email} <- Repo.one(query),
           {:ok, settings_user} <-
             Repo.update(SettingsUser.email_changeset(settings_user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(
               from(SettingsUserToken,
                 where: [settings_user_id: ^settings_user.id, context: ^context]
               )
             ) do
        {:ok, settings_user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the settings_user password.

  See `Assistant.Accounts.SettingsUser.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_settings_user_password(settings_user)
      %Ecto.Changeset{data: %SettingsUser{}}

  """
  def change_settings_user_password(settings_user, attrs \\ %{}, opts \\ []) do
    SettingsUser.password_changeset(settings_user, attrs, opts)
  end

  @doc """
  Updates the settings_user password.

  Returns a tuple with the updated settings_user, as well as a list of expired tokens.

  ## Examples

      iex> update_settings_user_password(settings_user, %{password: ...})
      {:ok, {%SettingsUser{}, [...]}}

      iex> update_settings_user_password(settings_user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_settings_user_password(settings_user, attrs) do
    settings_user
    |> SettingsUser.password_changeset(attrs)
    |> update_settings_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_settings_user_session_token(settings_user) do
    {token, settings_user_token} = SettingsUserToken.build_session_token(settings_user)
    Repo.insert!(settings_user_token)
    token
  end

  @doc """
  Gets the settings_user with the given signed token.

  If the token is valid `{settings_user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_settings_user_by_session_token(token) do
    {:ok, query} = SettingsUserToken.verify_session_token_query(token)

    case Repo.one(query) do
      {settings_user, token_inserted_at} ->
        case maybe_sync_and_authorize_settings_user(settings_user) do
          {:ok, synced_settings_user} -> {synced_settings_user, token_inserted_at}
          _ -> nil
        end

      nil ->
        nil
    end
  end

  @doc """
  Gets the settings_user with the given magic link token.
  """
  def get_settings_user_by_magic_link_token(token) do
    with {:ok, query} <- SettingsUserToken.verify_magic_link_token_query(token),
         {settings_user, _token} <- Repo.one(query),
         {:ok, synced_settings_user} <- maybe_sync_and_authorize_settings_user(settings_user) do
      synced_settings_user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the settings_user in by magic link.

  There are three cases to consider:

  1. The settings_user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The settings_user has not confirmed their email and no password is set.
     In this case, the settings_user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The settings_user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_settings_user_by_magic_link(token) do
    {:ok, query} = SettingsUserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%SettingsUser{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%SettingsUser{confirmed_at: nil} = settings_user, _token} ->
        with {:ok, _} <- maybe_sync_and_authorize_settings_user(settings_user),
             {:ok, {updated_settings_user, expired_tokens}} <-
               settings_user
               |> SettingsUser.confirm_changeset()
               |> update_settings_user_and_delete_all_tokens(),
             {:ok, synced_settings_user} <-
               maybe_sync_and_authorize_settings_user(updated_settings_user) do
          {:ok, {synced_settings_user, expired_tokens}}
        end

      {settings_user, token} ->
        with {:ok, synced_settings_user} <- maybe_sync_and_authorize_settings_user(settings_user) do
          Repo.delete!(token)
          {:ok, {synced_settings_user, []}}
        end

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given settings_user.

  ## Examples

      iex> deliver_settings_user_update_email_instructions(settings_user, current_email, &url(~p"/settings_users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_settings_user_update_email_instructions(
        %SettingsUser{} = settings_user,
        current_email,
        update_email_url_fun
      )
      when is_function(update_email_url_fun, 1) do
    {encoded_token, settings_user_token} =
      SettingsUserToken.build_email_token(settings_user, "change:#{current_email}")

    Repo.insert!(settings_user_token)

    SettingsUserNotifier.deliver_update_email_instructions(
      settings_user,
      update_email_url_fun.(encoded_token)
    )
  end

  @doc """
  Delivers the magic link login instructions to the given settings_user.
  """
  def deliver_login_instructions(%SettingsUser{} = settings_user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    with {:ok, _} <- maybe_sync_and_authorize_settings_user(settings_user) do
      {encoded_token, settings_user_token} =
        SettingsUserToken.build_email_token(settings_user, "login")

      Repo.insert!(settings_user_token)

      SettingsUserNotifier.deliver_login_instructions(
        settings_user,
        magic_link_url_fun.(encoded_token)
      )
    end
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_settings_user_session_token(token) do
    Repo.delete_all(from(SettingsUserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  defp maybe_validate_allowlist_registration(%Ecto.Changeset{} = changeset) do
    email = Ecto.Changeset.get_field(changeset, :email)

    if changeset.valid? and is_binary(email) and not email_allowed_by_allowlist?(email) do
      Ecto.Changeset.add_error(changeset, :email, "is not on the allow list")
    else
      changeset
    end
  end

  defp maybe_sync_new_settings_user_access({:ok, %SettingsUser{} = settings_user}) do
    maybe_sync_and_authorize_settings_user(settings_user)
  end

  defp maybe_sync_new_settings_user_access(other), do: other

  defp maybe_sync_and_authorize_settings_user(%SettingsUser{} = settings_user) do
    if SettingsUser.disabled?(settings_user) do
      {:error, :disabled}
    else
      with true <- email_allowed_by_allowlist?(settings_user.email),
           {:ok, synced_settings_user} <- sync_settings_user_access_from_allowlist(settings_user) do
        {:ok, synced_settings_user}
      else
        false -> {:error, :not_allowed}
        {:error, _} = error -> error
      end
    end
  end

  defp sync_settings_user_access_from_allowlist(%SettingsUser{} = settings_user) do
    if allowlist_enforced?() do
      desired =
        case active_allowlist_entry_for_email(settings_user.email) do
          %SettingsUserAllowlistEntry{} = entry ->
            base = %{
              is_admin: entry.is_admin,
              access_scopes: entry.scopes |> List.wrap() |> Enum.uniq()
            }

            if is_binary(entry.full_name) and entry.full_name != "" do
              Map.put(base, :full_name, entry.full_name)
            else
              base
            end

          nil ->
            %{is_admin: false, access_scopes: []}
        end

      needs_update =
        settings_user.is_admin != desired.is_admin or
          Enum.sort(List.wrap(settings_user.access_scopes)) != Enum.sort(desired[:access_scopes] || []) or
          (Map.has_key?(desired, :full_name) and settings_user.full_name != desired.full_name)

      if needs_update do
        settings_user
        |> Ecto.Changeset.change(desired)
        |> Repo.update()
      else
        {:ok, settings_user}
      end
    else
      {:ok, settings_user}
    end
  end

  defp email_allowed_by_allowlist?(email) when is_binary(email) do
    not allowlist_enforced?() or
      match?(%SettingsUserAllowlistEntry{}, active_allowlist_entry_for_email(email))
  end

  defp email_allowed_by_allowlist?(_), do: false

  defp allowlist_enforced? do
    Repo.exists?(from(e in SettingsUserAllowlistEntry, where: e.active == true))
  end

  defp active_allowlist_entry_for_email(email) when is_binary(email) do
    Repo.one(
      from(e in SettingsUserAllowlistEntry,
        where: e.email == ^normalize_email_param(email) and e.active == true,
        limit: 1
      )
    )
  end

  defp active_allowlist_entry_for_email(_), do: nil

  defp sync_matching_settings_user_access(email) when is_binary(email) do
    case Repo.get_by(SettingsUser, email: normalize_email_param(email)) do
      nil ->
        :ok

      %SettingsUser{} = settings_user ->
        case sync_settings_user_access_from_allowlist(settings_user) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end
    end
  end

  defp sync_matching_settings_user_access(_), do: :ok

  defp maybe_stamp_allowlist_actor(changeset, %SettingsUser{id: actor_id}) do
    changeset =
      Ecto.Changeset.put_change(changeset, :updated_by_settings_user_id, actor_id)

    if Ecto.get_meta(changeset.data, :state) == :built do
      Ecto.Changeset.put_change(changeset, :created_by_settings_user_id, actor_id)
    else
      changeset
    end
  end

  defp maybe_stamp_allowlist_actor(changeset, _actor), do: changeset

  defp normalize_email_param(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_email_param(_), do: nil

  ## Token helper

  defp update_settings_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, settings_user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(SettingsUserToken, settings_user_id: settings_user.id)

        Repo.delete_all(
          from(t in SettingsUserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id))
        )

        {:ok, {settings_user, tokens_to_expire}}
      end
    end)
  end

  defp normalize_oauth_email(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> {:error, :missing_email}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_oauth_email(_), do: {:error, :missing_email}

  defp normalize_oauth_display_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> case do
      "" -> nil
      value -> String.slice(value, 0, 160)
    end
  end

  defp normalize_oauth_display_name(_), do: nil

  defp maybe_put_confirmed_at(attrs, %SettingsUser{confirmed_at: nil}) do
    Map.put(attrs, :confirmed_at, DateTime.utc_now(:second))
  end

  defp maybe_put_confirmed_at(attrs, _settings_user), do: attrs

  defp maybe_put_display_name(attrs, %SettingsUser{display_name: existing}, name)
       when is_binary(name) and (is_nil(existing) or existing == "") do
    Map.put(attrs, :display_name, name)
  end

  defp maybe_put_display_name(attrs, _settings_user, _name), do: attrs

  ## OpenRouter

  @doc """
  Stores an OpenRouter API key (encrypted) for the given settings_user.
  """
  def save_openrouter_api_key(%SettingsUser{} = settings_user, api_key) when is_binary(api_key) do
    settings_user
    |> SettingsUser.openrouter_api_key_changeset(api_key)
    |> Repo.update()
  end

  @doc """
  Removes the OpenRouter API key for the given settings_user.
  """
  def delete_openrouter_api_key(%SettingsUser{} = settings_user) do
    settings_user
    |> SettingsUser.openrouter_api_key_changeset(nil)
    |> Repo.update()
  end

  @doc """
  Returns true if the settings_user has an OpenRouter API key stored.
  """
  def openrouter_connected?(%SettingsUser{openrouter_api_key: key}) when is_binary(key), do: true
  def openrouter_connected?(_), do: false

  ## Admin per-user key management

  @doc """
  Lists all settings_users with summary info for admin key management.

  Returns a list of maps with :id, :email, :display_name,
  :has_openrouter_key (boolean), and :has_linked_user (boolean).
  The actual API key value is never exposed.
  """
  def list_settings_users_for_admin(opts \\ []) do
    team_id = Keyword.get(opts, :team_id)

    query =
      from(su in SettingsUser,
        left_join: t in assoc(su, :team),
        order_by: [asc: su.email],
        select: %{
          id: su.id,
          email: su.email,
          display_name: su.display_name,
          is_admin: su.is_admin,
          is_super_admin: su.is_super_admin,
          team_id: su.team_id,
          team_name: t.name,
          disabled_at: su.disabled_at,
          can_manage_model_defaults: su.can_manage_model_defaults,
          has_openrouter_key: not is_nil(su.openrouter_api_key),
          has_openai_key: not is_nil(su.openai_api_key),
          has_linked_user: not is_nil(su.user_id)
        }
      )

    query =
      if team_id do
        from(su in query, where: su.team_id == ^team_id)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Sets an OpenRouter API key for a settings_user by ID (admin-provisioned).

  Returns `{:ok, settings_user}` or `{:error, :not_found}`.
  """
  def admin_set_openrouter_key(settings_user_id, api_key)
      when is_binary(settings_user_id) and is_binary(api_key) do
    case Repo.get(SettingsUser, settings_user_id) do
      nil ->
        {:error, :not_found}

      %SettingsUser{} = settings_user ->
        settings_user
        |> SettingsUser.openrouter_api_key_changeset(api_key)
        |> Repo.update()
    end
  end

  @doc """
  Clears the OpenRouter API key for a settings_user by ID (admin action).

  Returns `{:ok, settings_user}` or `{:error, :not_found}`.
  """
  def admin_clear_openrouter_key(settings_user_id) when is_binary(settings_user_id) do
    case Repo.get(SettingsUser, settings_user_id) do
      nil ->
        {:error, :not_found}

      %SettingsUser{} = settings_user ->
        settings_user
        |> SettingsUser.openrouter_api_key_changeset(nil)
        |> Repo.update()
    end
  end

  @doc """
  Returns `true` if the given settings_user is disabled.
  """
  def settings_user_disabled?(%SettingsUser{} = settings_user) do
    SettingsUser.disabled?(settings_user)
  end

  @doc """
  Returns detailed information about a settings_user for the admin detail view.

  Returns `{:ok, map}` or `{:error, :not_found}`.
  """
  def get_user_for_admin(settings_user_id) when is_binary(settings_user_id) do
    case Repo.get(SettingsUser, settings_user_id) do
      nil ->
        {:error, :not_found}

      %SettingsUser{} = su ->
        team_name =
          if su.team_id do
            case Repo.get(Team, su.team_id) do
              %Team{name: name} -> name
              _ -> nil
            end
          end

        {:ok,
         %{
           id: su.id,
           email: su.email,
           full_name: su.full_name,
           display_name: su.display_name,
           is_admin: su.is_admin,
           is_super_admin: su.is_super_admin,
           team_id: su.team_id,
           team_name: team_name,
           disabled_at: su.disabled_at,
           has_openrouter_key: is_binary(su.openrouter_api_key),
           has_openai_key: is_binary(su.openai_api_key),
           has_linked_user: not is_nil(su.user_id),
           user_id: su.user_id,
           access_scopes: su.access_scopes,
           model_defaults: su.model_defaults || %{},
           can_manage_model_defaults: su.can_manage_model_defaults,
           confirmed_at: su.confirmed_at,
           inserted_at: su.inserted_at,
           updated_at: su.updated_at
         }}
    end
  end

  @doc """
  Toggles whether a settings_user can manage their own model defaults.
  """
  def toggle_user_model_defaults_access(settings_user_id, enabled?)
      when is_binary(settings_user_id) and is_boolean(enabled?) do
    case Repo.get(SettingsUser, settings_user_id) do
      nil ->
        {:error, :not_found}

      %SettingsUser{} = settings_user ->
        settings_user
        |> SettingsUser.model_defaults_access_changeset(enabled?)
        |> Repo.update()
    end
  end

  @doc """
  Toggles the disabled state for a settings_user.

  When currently enabled, sets `disabled_at` to now and expires all session tokens.
  When currently disabled, clears `disabled_at` to nil.

  Returns `{:ok, updated_user, expired_tokens}` on success (expired_tokens is
  a list of `SettingsUserToken` structs suitable for `disconnect_sessions/1`).

  Guards:
  - Cannot disable yourself (`:cannot_disable_self`)
  - Cannot disable the last active admin (`:last_admin`)
  """
  def toggle_user_disabled(settings_user_id, actor_settings_user_id)
      when is_binary(settings_user_id) and is_binary(actor_settings_user_id) do
    if settings_user_id == actor_settings_user_id do
      {:error, :cannot_disable_self}
    else
      result =
        Repo.transact(fn ->
          case Repo.get(SettingsUser, settings_user_id) do
            nil ->
              {:error, :not_found}

            %SettingsUser{} = settings_user ->
              currently_disabled = SettingsUser.disabled?(settings_user)

              if not currently_disabled and settings_user.is_admin and last_active_admin?() do
                {:error, :last_admin}
              else
                new_disabled_at = if currently_disabled, do: nil, else: DateTime.utc_now(:second)

                with {:ok, updated_user} <-
                       settings_user
                       |> SettingsUser.disabled_changeset(new_disabled_at)
                       |> Repo.update() do
                  expired_tokens =
                    if new_disabled_at do
                      tokens =
                        Repo.all(
                          from(t in SettingsUserToken,
                            where:
                              t.settings_user_id == ^updated_user.id and t.context == "session"
                          )
                        )

                      Repo.delete_all(
                        from(t in SettingsUserToken,
                          where: t.id in ^Enum.map(tokens, & &1.id)
                        )
                      )

                      tokens
                    else
                      []
                    end

                  {:ok, {updated_user, expired_tokens}}
                end
              end
          end
        end)

      case result do
        {:ok, {updated_user, expired_tokens}} -> {:ok, updated_user, expired_tokens}
        error -> error
      end
    end
  end

  @doc """
  Deletes a settings_user by ID.

  Tokens are cascade-deleted by the database FK constraint.

  Guards:
  - Cannot delete yourself (`:cannot_delete_self`)
  - Cannot delete the last active admin (`:last_admin`)
  """
  def delete_settings_user(settings_user_id, actor_settings_user_id)
      when is_binary(settings_user_id) and is_binary(actor_settings_user_id) do
    if settings_user_id == actor_settings_user_id do
      {:error, :cannot_delete_self}
    else
      Repo.transact(fn ->
        case Repo.get(SettingsUser, settings_user_id) do
          nil ->
            {:error, :not_found}

          %SettingsUser{} = settings_user ->
            if settings_user.is_admin and last_active_admin?() do
              {:error, :last_admin}
            else
              Repo.delete(settings_user)
            end
        end
      end)
    end
  end

  @doc """
  Toggles admin status for a settings_user.

  Guards:
  - Cannot demote the last active admin (`:last_admin`)
  """
  @doc """
  Toggles admin status for a user. Only super_admins may call this.
  Cannot demote the last active admin or change super_admin status through this function.
  """
  def toggle_admin_status(settings_user_id, is_admin, actor \\ nil)

  def toggle_admin_status(settings_user_id, is_admin, actor)
      when is_binary(settings_user_id) and is_boolean(is_admin) do
    # Guard: only super_admins can assign/revoke admin
    if actor && not (actor.is_super_admin == true) do
      {:error, :not_authorized}
    else
      Repo.transact(fn ->
        case Repo.get(SettingsUser, settings_user_id) do
          nil ->
            {:error, :not_found}

          %SettingsUser{is_super_admin: true} ->
            {:error, :cannot_modify_super_admin}

          %SettingsUser{} = settings_user ->
            if not is_admin and settings_user.is_admin and last_active_admin?() do
              {:error, :last_admin}
            else
              settings_user
              |> Ecto.Changeset.change(is_admin: is_admin)
              |> Repo.update()
            end
        end
      end)
    end
  end

  # Returns true when there is exactly one active (non-disabled) admin.
  defp last_active_admin? do
    count =
      Repo.one(
        from(su in SettingsUser,
          where: su.is_admin == true and is_nil(su.disabled_at),
          select: count(su.id)
        )
      )

    count <= 1
  end

  @doc """
  Looks up the per-user OpenRouter API key via the chat user_id bridge.

  Returns the decrypted API key string, or nil if the user has no linked
  settings_user or no OpenRouter key stored.

  Fallback chain: direct lookup by user_id → single-admin fallback
  (see `CrossChannelBridge` for why this fallback exists).
  """
  @spec openrouter_key_for_user(String.t()) :: String.t() | nil
  def openrouter_key_for_user(user_id) when is_binary(user_id) do
    with {:ok, cast_user_id} <- Ecto.UUID.cast(user_id) do
      case Repo.one(
             from(su in SettingsUser,
               where: su.user_id == ^cast_user_id,
               select: su.openrouter_api_key
             )
           ) do
        nil ->
          # Direct lookup failed — try single-admin fallback
          case CrossChannelBridge.sole_key(:openrouter_api_key) do
            nil ->
              nil

            key ->
              CrossChannelBridge.log_fallback(user_id, :openrouter_api_key)
              key
          end

        "" ->
          nil

        key when is_binary(key) ->
          key
      end
    else
      :error -> nil
    end
  end

  def openrouter_key_for_user(_), do: nil

  ## OpenAI

  @doc """
  Stores an OpenAI API key (encrypted) for the given settings_user.
  """
  def save_openai_api_key(%SettingsUser{} = settings_user, api_key) when is_binary(api_key) do
    settings_user
    |> SettingsUser.openai_api_key_changeset(api_key)
    |> Repo.update()
  end

  @doc """
  Stores OpenAI OAuth credentials for the given settings_user.
  """
  @spec save_openai_oauth_credentials(%SettingsUser{}, map()) ::
          {:ok, %SettingsUser{}} | {:error, Ecto.Changeset.t()}
  def save_openai_oauth_credentials(%SettingsUser{} = settings_user, attrs) when is_map(attrs) do
    settings_user
    |> SettingsUser.openai_oauth_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Stores OpenAI OAuth credentials by linked chat `user_id`.

  Returns `{:error, :not_found}` if no settings_user is linked to the given user_id.
  """
  @spec save_openai_oauth_credentials_for_user(String.t(), map()) ::
          {:ok, %SettingsUser{}} | {:error, Ecto.Changeset.t() | :not_found}
  def save_openai_oauth_credentials_for_user(user_id, attrs)
      when is_binary(user_id) and is_map(attrs) do
    with {:ok, cast_user_id} <- Ecto.UUID.cast(user_id),
         %SettingsUser{} = settings_user <- Repo.get_by(SettingsUser, user_id: cast_user_id) do
      save_openai_oauth_credentials(settings_user, attrs)
    else
      :error -> {:error, :not_found}
      nil -> {:error, :not_found}
    end
  end

  def save_openai_oauth_credentials_for_user(_, _), do: {:error, :not_found}

  @doc """
  Removes the OpenAI API key for the given settings_user.
  """
  def delete_openai_api_key(%SettingsUser{} = settings_user) do
    settings_user
    |> SettingsUser.openai_api_key_changeset(nil)
    |> Repo.update()
  end

  @doc """
  Returns true if the settings_user has an OpenAI API key stored.
  """
  def openai_connected?(%SettingsUser{openai_api_key: key}) when is_binary(key), do: true
  def openai_connected?(_), do: false

  @doc """
  Looks up the per-user OpenAI API key via the chat user_id bridge.

  Returns the decrypted API key string, or nil if the user has no linked
  settings_user or no OpenAI key stored.

  Fallback chain: direct lookup by user_id → single-admin fallback
  (see `CrossChannelBridge` for why this fallback exists).
  """
  @spec openai_key_for_user(String.t()) :: String.t() | nil
  def openai_key_for_user(user_id) when is_binary(user_id) do
    with {:ok, cast_user_id} <- Ecto.UUID.cast(user_id) do
      case Repo.one(
             from(su in SettingsUser,
               where: su.user_id == ^cast_user_id,
               select: su.openai_api_key
             )
           ) do
        nil ->
          # Direct lookup failed — try single-admin fallback
          case CrossChannelBridge.sole_key(:openai_api_key) do
            nil ->
              nil

            key ->
              CrossChannelBridge.log_fallback(user_id, :openai_api_key)
              key
          end

        "" ->
          nil

        key when is_binary(key) ->
          key
      end
    else
      :error -> nil
    end
  end

  def openai_key_for_user(_), do: nil

  @doc """
  Looks up full OpenAI credentials via the chat user_id bridge.

  Returns:
    - `:auth_type` — `"api_key"` or `"oauth"` when known
    - `:access_token` — key or OAuth access token
    - `:refresh_token` — OAuth refresh token (oauth mode only)
    - `:account_id` — ChatGPT account/org id (oauth mode only)
    - `:expires_at` — UTC expiry timestamp when available

  Fallback chain: direct lookup by user_id → single-admin fallback
  (see `CrossChannelBridge` for why this fallback exists).
  """
  @spec openai_credentials_for_user(String.t()) :: map() | nil
  def openai_credentials_for_user(user_id) when is_binary(user_id) do
    with {:ok, cast_user_id} <- Ecto.UUID.cast(user_id) do
      row =
        Repo.one(
          from(su in SettingsUser,
            where: su.user_id == ^cast_user_id,
            select: %{
              auth_type: su.openai_auth_type,
              access_token: su.openai_api_key,
              refresh_token: su.openai_refresh_token,
              account_id: su.openai_account_id,
              expires_at: su.openai_expires_at
            }
          )
        )

      cond do
        is_map(row) and is_binary(row.access_token) and row.access_token != "" ->
          row

        true ->
          # Direct lookup failed — try single-admin fallback
          case CrossChannelBridge.sole_credentials(:openai) do
            nil ->
              nil

            creds ->
              CrossChannelBridge.log_fallback(user_id, :openai_credentials)
              creds
          end
      end
    else
      :error -> nil
    end
  end

  def openai_credentials_for_user(_), do: nil
end

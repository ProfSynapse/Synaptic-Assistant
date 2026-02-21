defmodule Assistant.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Assistant.Repo

  alias Assistant.Accounts.{SettingsUser, SettingsUserToken, SettingsUserNotifier}

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
    if SettingsUser.valid_password?(settings_user, password), do: settings_user
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
    |> Repo.insert()
  end

  @doc """
  Gets or creates a settings user from Google OAuth claims and marks the account as confirmed.
  """
  def get_or_register_settings_user_from_google(attrs) when is_map(attrs) do
    with {:ok, email} <- normalize_oauth_email(Map.get(attrs, "email") || Map.get(attrs, :email)) do
      display_name = normalize_oauth_display_name(Map.get(attrs, "name") || Map.get(attrs, :name))

      case get_settings_user_by_email(email) do
        nil ->
          %SettingsUser{}
          |> SettingsUser.email_changeset(%{email: email}, validate_changed: false)
          |> Ecto.Changeset.change(
            display_name: display_name,
            confirmed_at: DateTime.utc_now(:second)
          )
          |> Repo.insert()

        %SettingsUser{} = settings_user ->
          attrs =
            %{}
            |> maybe_put_confirmed_at(settings_user)
            |> maybe_put_display_name(settings_user, display_name)

          if map_size(attrs) == 0 do
            {:ok, settings_user}
          else
            settings_user
            |> Ecto.Changeset.change(attrs)
            |> Repo.update()
          end
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
    Repo.one(query)
  end

  @doc """
  Gets the settings_user with the given magic link token.
  """
  def get_settings_user_by_magic_link_token(token) do
    with {:ok, query} <- SettingsUserToken.verify_magic_link_token_query(token),
         {settings_user, _token} <- Repo.one(query) do
      settings_user
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
        settings_user
        |> SettingsUser.confirm_changeset()
        |> update_settings_user_and_delete_all_tokens()

      {settings_user, token} ->
        Repo.delete!(token)
        {:ok, {settings_user, []}}

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
    {encoded_token, settings_user_token} =
      SettingsUserToken.build_email_token(settings_user, "login")

    Repo.insert!(settings_user_token)

    SettingsUserNotifier.deliver_login_instructions(
      settings_user,
      magic_link_url_fun.(encoded_token)
    )
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_settings_user_session_token(token) do
    Repo.delete_all(from(SettingsUserToken, where: [token: ^token, context: "session"]))
    :ok
  end

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

  @doc """
  Looks up the per-user OpenRouter API key via the chat user_id bridge.

  Returns the decrypted API key string, or nil if the user has no linked
  settings_user or no OpenRouter key stored.
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
        nil -> nil
        "" -> nil
        key when is_binary(key) -> key
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
        nil -> nil
        "" -> nil
        key when is_binary(key) -> key
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
  """
  @spec openai_credentials_for_user(String.t()) :: map() | nil
  def openai_credentials_for_user(user_id) when is_binary(user_id) do
    with {:ok, cast_user_id} <- Ecto.UUID.cast(user_id),
         %{} = row <-
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
           ),
         true <- is_binary(row.access_token) and row.access_token != "" do
      row
    else
      _ -> nil
    end
  end

  def openai_credentials_for_user(_), do: nil
end

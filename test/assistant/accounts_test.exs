defmodule Assistant.AccountsTest do
  use Assistant.DataCase

  alias Assistant.Accounts
  alias Assistant.Billing

  import Assistant.AccountsFixtures
  alias Assistant.Accounts.{SettingsUser, SettingsUserToken}

  describe "get_settings_user_by_email/1" do
    test "does not return the settings_user if the email does not exist" do
      refute Accounts.get_settings_user_by_email("unknown@example.com")
    end

    test "returns the settings_user if the email exists" do
      %{id: id} = settings_user = settings_user_fixture()
      assert %SettingsUser{id: ^id} = Accounts.get_settings_user_by_email(settings_user.email)
    end
  end

  describe "get_settings_user_by_email_and_password/2" do
    test "does not return the settings_user if the email does not exist" do
      refute Accounts.get_settings_user_by_email_and_password(
               "unknown@example.com",
               "hello world!"
             )
    end

    test "does not return the settings_user if the password is not valid" do
      settings_user = settings_user_fixture() |> set_password()
      refute Accounts.get_settings_user_by_email_and_password(settings_user.email, "invalid")
    end

    test "returns the settings_user if the email and password are valid" do
      %{id: id} = settings_user = settings_user_fixture() |> set_password()

      assert %SettingsUser{id: ^id} =
               Accounts.get_settings_user_by_email_and_password(
                 settings_user.email,
                 valid_settings_user_password()
               )
    end
  end

  describe "get_settings_user!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_settings_user!("11111111-1111-1111-1111-111111111111")
      end
    end

    test "returns the settings_user with the given id" do
      %{id: id} = settings_user = settings_user_fixture()
      assert %SettingsUser{id: ^id} = Accounts.get_settings_user!(settings_user.id)
    end
  end

  describe "register_settings_user/1" do
    test "requires email to be set" do
      {:error, changeset} = Accounts.register_settings_user(%{})

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates email when given" do
      {:error, changeset} = Accounts.register_settings_user(%{email: "not valid"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "validates maximum values for email for security" do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Accounts.register_settings_user(%{email: too_long})
      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "validates email uniqueness" do
      %{email: email} = settings_user_fixture()
      {:error, changeset} = Accounts.register_settings_user(%{email: email})
      assert "has already been taken" in errors_on(changeset).email

      # Now try with the uppercased email too, to check that email case is ignored.
      {:error, changeset} = Accounts.register_settings_user(%{email: String.upcase(email)})
      assert "has already been taken" in errors_on(changeset).email
    end

    test "registers settings_users without password" do
      email = unique_settings_user_email()

      {:ok, settings_user} =
        Accounts.register_settings_user(valid_settings_user_attributes(email: email))

      assert settings_user.email == email
      assert is_nil(settings_user.hashed_password)
      assert is_nil(settings_user.confirmed_at)
      assert is_nil(settings_user.password)
    end

    test "allows registration even when allowlist has other active entries" do
      {:ok, _entry} =
        Accounts.upsert_settings_user_allowlist_entry(%{
          email: "allowed@example.com",
          active: true,
          is_admin: false,
          scopes: ["chat"]
        })

      assert {:ok, settings_user} =
               Accounts.register_settings_user(%{email: unique_settings_user_email()})

      refute settings_user.is_admin
      assert settings_user.access_scopes == []
    end

    test "syncs admin flag and access scopes from allowlist on registration" do
      email = unique_settings_user_email()

      {:ok, _entry} =
        Accounts.upsert_settings_user_allowlist_entry(%{
          email: email,
          active: true,
          is_admin: true,
          scopes: ["chat", "analytics"]
        })

      {:ok, settings_user} = Accounts.register_settings_user(%{email: email})

      assert settings_user.is_admin
      assert Enum.sort(settings_user.access_scopes) == ["analytics", "chat"]
    end
  end

  describe "sudo_mode?/2" do
    test "validates the authenticated_at time" do
      now = DateTime.utc_now()

      assert Accounts.sudo_mode?(%SettingsUser{authenticated_at: DateTime.utc_now()})
      assert Accounts.sudo_mode?(%SettingsUser{authenticated_at: DateTime.add(now, -19, :minute)})
      refute Accounts.sudo_mode?(%SettingsUser{authenticated_at: DateTime.add(now, -21, :minute)})

      # minute override
      refute Accounts.sudo_mode?(
               %SettingsUser{authenticated_at: DateTime.add(now, -11, :minute)},
               -10
             )

      # not authenticated
      refute Accounts.sudo_mode?(%SettingsUser{})
    end
  end

  describe "change_settings_user_email/3" do
    test "returns a settings_user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_settings_user_email(%SettingsUser{})
      assert changeset.required == [:email]
    end
  end

  describe "deliver_settings_user_update_email_instructions/3" do
    setup do
      %{settings_user: settings_user_fixture()}
    end

    test "sends token through notification", %{settings_user: settings_user} do
      token =
        extract_settings_user_token(fn url ->
          Accounts.deliver_settings_user_update_email_instructions(
            settings_user,
            "current@example.com",
            url
          )
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)

      assert settings_user_token =
               Repo.get_by(SettingsUserToken, token: :crypto.hash(:sha256, token))

      assert settings_user_token.settings_user_id == settings_user.id
      assert settings_user_token.sent_to == settings_user.email
      assert settings_user_token.context == "change:current@example.com"
    end
  end

  describe "update_settings_user_email/2" do
    setup do
      settings_user = unconfirmed_settings_user_fixture()
      email = unique_settings_user_email()

      token =
        extract_settings_user_token(fn url ->
          Accounts.deliver_settings_user_update_email_instructions(
            %{settings_user | email: email},
            settings_user.email,
            url
          )
        end)

      %{settings_user: settings_user, token: token, email: email}
    end

    test "updates the email with a valid token", %{
      settings_user: settings_user,
      token: token,
      email: email
    } do
      assert {:ok, %{email: ^email}} = Accounts.update_settings_user_email(settings_user, token)
      changed_settings_user = Repo.get!(SettingsUser, settings_user.id)
      assert changed_settings_user.email != settings_user.email
      assert changed_settings_user.email == email
      refute Repo.get_by(SettingsUserToken, settings_user_id: settings_user.id)
    end

    test "does not update email with invalid token", %{settings_user: settings_user} do
      assert Accounts.update_settings_user_email(settings_user, "oops") ==
               {:error, :transaction_aborted}

      assert Repo.get!(SettingsUser, settings_user.id).email == settings_user.email
      assert Repo.get_by(SettingsUserToken, settings_user_id: settings_user.id)
    end

    test "does not update email if settings_user email changed", %{
      settings_user: settings_user,
      token: token
    } do
      assert Accounts.update_settings_user_email(
               %{settings_user | email: "current@example.com"},
               token
             ) ==
               {:error, :transaction_aborted}

      assert Repo.get!(SettingsUser, settings_user.id).email == settings_user.email
      assert Repo.get_by(SettingsUserToken, settings_user_id: settings_user.id)
    end

    test "does not update email if token expired", %{settings_user: settings_user, token: token} do
      {1, nil} = Repo.update_all(SettingsUserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      assert Accounts.update_settings_user_email(settings_user, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(SettingsUser, settings_user.id).email == settings_user.email
      assert Repo.get_by(SettingsUserToken, settings_user_id: settings_user.id)
    end
  end

  describe "change_settings_user_password/3" do
    test "returns a settings_user changeset" do
      assert %Ecto.Changeset{} =
               changeset = Accounts.change_settings_user_password(%SettingsUser{})

      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_settings_user_password(
          %SettingsUser{},
          %{
            "password" => "new valid password"
          },
          hash_password: false
        )

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_settings_user_password/2" do
    setup do
      %{settings_user: settings_user_fixture()}
    end

    test "validates password", %{settings_user: settings_user} do
      {:error, changeset} =
        Accounts.update_settings_user_password(settings_user, %{
          password: "short",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 8 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{settings_user: settings_user} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.update_settings_user_password(settings_user, %{password: too_long})

      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{settings_user: settings_user} do
      {:ok, {settings_user, expired_tokens}} =
        Accounts.update_settings_user_password(settings_user, %{
          password: "new valid password"
        })

      assert expired_tokens == []
      assert is_nil(settings_user.password)

      assert Accounts.get_settings_user_by_email_and_password(
               settings_user.email,
               "new valid password"
             )
    end

    test "deletes all tokens for the given settings_user", %{settings_user: settings_user} do
      _ = Accounts.generate_settings_user_session_token(settings_user)

      {:ok, {_, _}} =
        Accounts.update_settings_user_password(settings_user, %{
          password: "new valid password"
        })

      refute Repo.get_by(SettingsUserToken, settings_user_id: settings_user.id)
    end
  end

  describe "generate_settings_user_session_token/1" do
    setup do
      %{settings_user: settings_user_fixture()}
    end

    test "generates a token", %{settings_user: settings_user} do
      token = Accounts.generate_settings_user_session_token(settings_user)
      assert settings_user_token = Repo.get_by(SettingsUserToken, token: token)
      assert settings_user_token.context == "session"
      assert settings_user_token.authenticated_at != nil

      # Creating the same token for another settings_user should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%SettingsUserToken{
          token: settings_user_token.token,
          settings_user_id: settings_user_fixture().id,
          context: "session"
        })
      end
    end

    test "duplicates the authenticated_at of given settings_user in new token", %{
      settings_user: settings_user
    } do
      settings_user = %{
        settings_user
        | authenticated_at: DateTime.add(DateTime.utc_now(:second), -3600)
      }

      token = Accounts.generate_settings_user_session_token(settings_user)
      assert settings_user_token = Repo.get_by(SettingsUserToken, token: token)
      assert settings_user_token.authenticated_at == settings_user.authenticated_at

      assert DateTime.compare(settings_user_token.inserted_at, settings_user.authenticated_at) ==
               :gt
    end
  end

  describe "get_settings_user_by_session_token/1" do
    setup do
      settings_user = settings_user_fixture()
      token = Accounts.generate_settings_user_session_token(settings_user)
      %{settings_user: settings_user, token: token}
    end

    test "returns settings_user by token", %{settings_user: settings_user, token: token} do
      assert {session_settings_user, token_inserted_at} =
               Accounts.get_settings_user_by_session_token(token)

      assert session_settings_user.id == settings_user.id
      assert session_settings_user.authenticated_at != nil
      assert token_inserted_at != nil
    end

    test "does not return settings_user for invalid token" do
      refute Accounts.get_settings_user_by_session_token("oops")
    end

    test "does not return settings_user for expired token", %{token: token} do
      dt = ~N[2020-01-01 00:00:00]
      {1, nil} = Repo.update_all(SettingsUserToken, set: [inserted_at: dt, authenticated_at: dt])
      refute Accounts.get_settings_user_by_session_token(token)
    end
  end

  describe "get_settings_user_by_magic_link_token/1" do
    setup do
      settings_user = settings_user_fixture()
      {encoded_token, _hashed_token} = generate_settings_user_magic_link_token(settings_user)
      %{settings_user: settings_user, token: encoded_token}
    end

    test "returns settings_user by token", %{settings_user: settings_user, token: token} do
      assert session_settings_user = Accounts.get_settings_user_by_magic_link_token(token)
      assert session_settings_user.id == settings_user.id
    end

    test "does not return settings_user for invalid token" do
      refute Accounts.get_settings_user_by_magic_link_token("oops")
    end

    test "does not return settings_user for expired token", %{token: token} do
      {1, nil} = Repo.update_all(SettingsUserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      refute Accounts.get_settings_user_by_magic_link_token(token)
    end
  end

  describe "login_settings_user_by_magic_link/1" do
    test "confirms settings_user and expires tokens" do
      settings_user = unconfirmed_settings_user_fixture()
      refute settings_user.confirmed_at
      {encoded_token, hashed_token} = generate_settings_user_magic_link_token(settings_user)

      assert {:ok, {settings_user, [%{token: ^hashed_token}]}} =
               Accounts.login_settings_user_by_magic_link(encoded_token)

      assert settings_user.confirmed_at
    end

    test "returns settings_user and (deleted) token for confirmed settings_user" do
      settings_user = settings_user_fixture()
      assert settings_user.confirmed_at
      {encoded_token, _hashed_token} = generate_settings_user_magic_link_token(settings_user)

      assert {:ok, {logged_in_settings_user, []}} =
               Accounts.login_settings_user_by_magic_link(encoded_token)

      assert logged_in_settings_user.id == settings_user.id

      # one time use only
      assert {:error, :not_found} = Accounts.login_settings_user_by_magic_link(encoded_token)
    end

    test "raises when unconfirmed settings_user has password set" do
      settings_user = unconfirmed_settings_user_fixture()
      {1, nil} = Repo.update_all(SettingsUser, set: [hashed_password: "hashed"])
      {encoded_token, _hashed_token} = generate_settings_user_magic_link_token(settings_user)

      assert_raise RuntimeError, ~r/magic link log in is not allowed/, fn ->
        Accounts.login_settings_user_by_magic_link(encoded_token)
      end
    end

    test "provisions a free billing account after confirmation" do
      settings_user = unconfirmed_settings_user_fixture()
      {encoded_token, _hashed_token} = generate_settings_user_magic_link_token(settings_user)

      assert {:ok, {updated_settings_user, _expired_tokens}} =
               Accounts.login_settings_user_by_magic_link(encoded_token)

      assert is_binary(updated_settings_user.billing_account_id)

      assert Billing.free_storage_limit_bytes() ==
               Billing.storage_policy(updated_settings_user).included_bytes
    end
  end

  describe "get_or_register_settings_user_from_google/1" do
    test "provisions a free billing account for new confirmed users" do
      assert {:ok, settings_user} =
               Accounts.get_or_register_settings_user_from_google(%{
                 "email" => unique_settings_user_email(),
                 "name" => "Google User"
               })

      assert settings_user.confirmed_at
      assert is_binary(settings_user.billing_account_id)

      assert Billing.free_storage_limit_bytes() ==
               Billing.storage_policy(settings_user).included_bytes
    end
  end

  describe "delete_settings_user_session_token/1" do
    test "deletes the token" do
      settings_user = settings_user_fixture()
      token = Accounts.generate_settings_user_session_token(settings_user)
      assert Accounts.delete_settings_user_session_token(token) == :ok
      refute Accounts.get_settings_user_by_session_token(token)
    end
  end

  describe "deliver_login_instructions/2" do
    setup do
      %{settings_user: unconfirmed_settings_user_fixture()}
    end

    test "sends token through notification", %{settings_user: settings_user} do
      token =
        extract_settings_user_token(fn url ->
          Accounts.deliver_login_instructions(settings_user, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)

      assert settings_user_token =
               Repo.get_by(SettingsUserToken, token: :crypto.hash(:sha256, token))

      assert settings_user_token.settings_user_id == settings_user.id
      assert settings_user_token.sent_to == settings_user.email
      assert settings_user_token.context == "login"
    end
  end

  ## OpenRouter

  describe "save_openrouter_api_key/2" do
    setup do
      %{settings_user: settings_user_fixture()}
    end

    test "stores encrypted API key", %{settings_user: settings_user} do
      assert {:ok, updated} = Accounts.save_openrouter_api_key(settings_user, "sk-or-test-key")
      assert updated.openrouter_api_key == "sk-or-test-key"

      # Verify persisted to DB
      reloaded = Repo.get!(SettingsUser, settings_user.id)
      assert reloaded.openrouter_api_key == "sk-or-test-key"
    end

    test "overwrites existing key", %{settings_user: settings_user} do
      {:ok, _} = Accounts.save_openrouter_api_key(settings_user, "sk-or-first-key")
      {:ok, updated} = Accounts.save_openrouter_api_key(settings_user, "sk-or-second-key")
      assert updated.openrouter_api_key == "sk-or-second-key"

      reloaded = Repo.get!(SettingsUser, settings_user.id)
      assert reloaded.openrouter_api_key == "sk-or-second-key"
    end
  end

  describe "delete_openrouter_api_key/1" do
    setup do
      %{settings_user: settings_user_fixture()}
    end

    test "removes stored key", %{settings_user: settings_user} do
      {:ok, settings_user} = Accounts.save_openrouter_api_key(settings_user, "sk-or-to-delete")
      assert settings_user.openrouter_api_key == "sk-or-to-delete"

      {:ok, updated} = Accounts.delete_openrouter_api_key(settings_user)
      assert is_nil(updated.openrouter_api_key)

      reloaded = Repo.get!(SettingsUser, settings_user.id)
      assert is_nil(reloaded.openrouter_api_key)
    end

    test "succeeds when no key stored", %{settings_user: settings_user} do
      assert is_nil(settings_user.openrouter_api_key)
      assert {:ok, updated} = Accounts.delete_openrouter_api_key(settings_user)
      assert is_nil(updated.openrouter_api_key)
    end
  end

  describe "openrouter_connected?/1" do
    test "returns true when key exists" do
      assert Accounts.openrouter_connected?(%SettingsUser{openrouter_api_key: "sk-or-key"})
    end

    test "returns false when key is nil" do
      refute Accounts.openrouter_connected?(%SettingsUser{openrouter_api_key: nil})
    end

    test "returns false for non-SettingsUser" do
      refute Accounts.openrouter_connected?(nil)
    end
  end

  ## Admin per-user key management

  describe "list_settings_users_for_admin/0" do
    test "returns empty list when no users exist" do
      # Clean slate — DataCase sandbox starts empty
      assert Accounts.list_settings_users_for_admin() == []
    end

    test "returns users with correct fields" do
      user = settings_user_fixture()

      [result] = Accounts.list_settings_users_for_admin()

      assert result.id == user.id
      assert result.email == user.email
      assert is_boolean(result.has_openrouter_key)
      assert is_boolean(result.has_linked_user)
      assert Map.has_key?(result, :display_name)
    end

    test "shows has_openrouter_key as false when no key set" do
      settings_user_fixture()

      [result] = Accounts.list_settings_users_for_admin()
      refute result.has_openrouter_key
    end

    test "shows has_openrouter_key as true when key is set" do
      user = settings_user_fixture()
      {:ok, _} = Accounts.save_openrouter_api_key(user, "sk-or-test-key")

      [result] = Accounts.list_settings_users_for_admin()
      assert result.has_openrouter_key
    end

    test "shows has_linked_user as false when no chat user linked" do
      settings_user_fixture()

      [result] = Accounts.list_settings_users_for_admin()
      refute result.has_linked_user
    end

    test "shows has_linked_user as true when chat user is linked" do
      user = settings_user_fixture()

      # Create a chat user and link it
      {:ok, chat_user} =
        %Assistant.Schemas.User{}
        |> Assistant.Schemas.User.changeset(%{
          external_id: "ext-#{System.unique_integer([:positive])}",
          channel: "google_chat"
        })
        |> Repo.insert()

      user
      |> Ecto.Changeset.change(%{user_id: chat_user.id})
      |> Repo.update!()

      [result] = Accounts.list_settings_users_for_admin()
      assert result.has_linked_user
    end

    test "returns users ordered by email" do
      # Create users with known emails that sort predictably
      settings_user_fixture(%{email: "zara@example.com"})
      settings_user_fixture(%{email: "alice@example.com"})
      settings_user_fixture(%{email: "mike@example.com"})

      results = Accounts.list_settings_users_for_admin()
      emails = Enum.map(results, & &1.email)

      assert emails == Enum.sort(emails)
    end

    test "returns multiple users with mixed key states" do
      user_with_key = settings_user_fixture(%{email: "has-key@example.com"})
      _user_without_key = settings_user_fixture(%{email: "no-key@example.com"})

      {:ok, _} = Accounts.save_openrouter_api_key(user_with_key, "sk-or-admin-test")

      results = Accounts.list_settings_users_for_admin()
      assert length(results) == 2

      keyed = Enum.find(results, &(&1.email == "has-key@example.com"))
      unkeyed = Enum.find(results, &(&1.email == "no-key@example.com"))

      assert keyed.has_openrouter_key
      refute unkeyed.has_openrouter_key
    end
  end

  describe "admin_set_openrouter_key/2" do
    setup do
      %{settings_user: settings_user_fixture()}
    end

    test "sets key successfully", %{settings_user: settings_user} do
      assert {:ok, updated} =
               Accounts.admin_set_openrouter_key(settings_user.id, "sk-or-admin-key")

      assert updated.openrouter_api_key == "sk-or-admin-key"
    end

    test "key is persisted and encrypted in DB", %{settings_user: settings_user} do
      {:ok, _} = Accounts.admin_set_openrouter_key(settings_user.id, "sk-or-persist-test")

      reloaded = Repo.get!(SettingsUser, settings_user.id)
      assert reloaded.openrouter_api_key == "sk-or-persist-test"
    end

    test "overwrites an existing key", %{settings_user: settings_user} do
      {:ok, _} = Accounts.admin_set_openrouter_key(settings_user.id, "sk-or-first")
      {:ok, updated} = Accounts.admin_set_openrouter_key(settings_user.id, "sk-or-second")

      assert updated.openrouter_api_key == "sk-or-second"

      reloaded = Repo.get!(SettingsUser, settings_user.id)
      assert reloaded.openrouter_api_key == "sk-or-second"
    end

    test "returns :not_found for nonexistent user ID" do
      fake_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Accounts.admin_set_openrouter_key(fake_id, "sk-or-key")
    end
  end

  describe "admin_clear_openrouter_key/1" do
    setup do
      %{settings_user: settings_user_fixture()}
    end

    test "clears an existing key", %{settings_user: settings_user} do
      {:ok, _} = Accounts.save_openrouter_api_key(settings_user, "sk-or-to-clear")

      assert {:ok, updated} = Accounts.admin_clear_openrouter_key(settings_user.id)
      assert is_nil(updated.openrouter_api_key)

      reloaded = Repo.get!(SettingsUser, settings_user.id)
      assert is_nil(reloaded.openrouter_api_key)
    end

    test "succeeds when key is already nil", %{settings_user: settings_user} do
      assert is_nil(settings_user.openrouter_api_key)
      assert {:ok, updated} = Accounts.admin_clear_openrouter_key(settings_user.id)
      assert is_nil(updated.openrouter_api_key)
    end

    test "returns :not_found for nonexistent user ID" do
      fake_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Accounts.admin_clear_openrouter_key(fake_id)
    end
  end

  describe "openrouter_key_for_user/1 cross-channel fallback" do
    setup do
      # Create a real chat user (e.g., Telegram)
      {:ok, chat_user} =
        %Assistant.Schemas.User{}
        |> Assistant.Schemas.User.changeset(%{
          external_id: "tg-#{System.unique_integer([:positive])}",
          channel: "telegram"
        })
        |> Repo.insert()

      # Create a settings pseudo-user (what ensure_linked_user used to create)
      {:ok, pseudo_user} =
        %Assistant.Schemas.User{}
        |> Assistant.Schemas.User.changeset(%{
          external_id: "settings:pseudo-#{System.unique_integer([:positive])}",
          channel: "settings"
        })
        |> Repo.insert()

      # Create a settings_user linked to the pseudo-user (the broken state)
      settings_user = settings_user_fixture()

      settings_user =
        settings_user
        |> Ecto.Changeset.change(%{user_id: pseudo_user.id})
        |> Repo.update!()

      %{chat_user: chat_user, pseudo_user: pseudo_user, settings_user: settings_user}
    end

    test "returns nil when no key is stored", %{chat_user: chat_user} do
      assert is_nil(Accounts.openrouter_key_for_user(chat_user.id))
    end

    test "falls back to sole settings_user key when direct lookup fails", %{
      chat_user: chat_user,
      settings_user: settings_user
    } do
      # Store an OpenRouter key on the settings_user (linked to pseudo-user)
      {:ok, _} = Accounts.save_openrouter_api_key(settings_user, "sk-or-cross-channel")

      # Direct lookup by chat_user.id would fail (settings_user.user_id != chat_user.id)
      # But the single-admin fallback should return the key
      assert Accounts.openrouter_key_for_user(chat_user.id) == "sk-or-cross-channel"
    end

    test "returns nil when multiple settings_users have keys (ambiguous)", %{
      chat_user: chat_user,
      settings_user: settings_user
    } do
      {:ok, _} = Accounts.save_openrouter_api_key(settings_user, "sk-or-first")

      # Create a second settings_user with a key
      second_su = settings_user_fixture(%{email: "second@example.com"})
      {:ok, _} = Accounts.save_openrouter_api_key(second_su, "sk-or-second")

      # Ambiguous: two settings_users with keys, fallback returns nil
      assert is_nil(Accounts.openrouter_key_for_user(chat_user.id))
    end

    test "direct lookup works when settings_user is properly linked", %{chat_user: chat_user} do
      # Create a properly-linked settings_user
      proper_su = settings_user_fixture(%{email: "proper@example.com"})

      proper_su =
        proper_su
        |> Ecto.Changeset.change(%{user_id: chat_user.id})
        |> Repo.update!()

      {:ok, _} = Accounts.save_openrouter_api_key(proper_su, "sk-or-direct")

      assert Accounts.openrouter_key_for_user(chat_user.id) == "sk-or-direct"
    end
  end

  describe "openai_credentials_for_user/1 cross-channel fallback" do
    setup do
      {:ok, chat_user} =
        %Assistant.Schemas.User{}
        |> Assistant.Schemas.User.changeset(%{
          external_id: "tg-#{System.unique_integer([:positive])}",
          channel: "telegram"
        })
        |> Repo.insert()

      {:ok, pseudo_user} =
        %Assistant.Schemas.User{}
        |> Assistant.Schemas.User.changeset(%{
          external_id: "settings:pseudo-#{System.unique_integer([:positive])}",
          channel: "settings"
        })
        |> Repo.insert()

      settings_user = settings_user_fixture()

      settings_user =
        settings_user
        |> Ecto.Changeset.change(%{user_id: pseudo_user.id})
        |> Repo.update!()

      %{chat_user: chat_user, pseudo_user: pseudo_user, settings_user: settings_user}
    end

    test "returns nil when no OpenAI key is stored", %{chat_user: chat_user} do
      assert is_nil(Accounts.openai_credentials_for_user(chat_user.id))
    end

    test "falls back to sole settings_user credentials when direct lookup fails", %{
      chat_user: chat_user,
      settings_user: settings_user
    } do
      {:ok, _} = Accounts.save_openai_api_key(settings_user, "sk-openai-cross-channel")

      result = Accounts.openai_credentials_for_user(chat_user.id)
      assert result.access_token == "sk-openai-cross-channel"
      assert result.auth_type == "api_key"
    end

    test "returns nil when multiple settings_users have OpenAI keys", %{
      chat_user: chat_user,
      settings_user: settings_user
    } do
      {:ok, _} = Accounts.save_openai_api_key(settings_user, "sk-openai-first")

      second_su = settings_user_fixture(%{email: "second-ai@example.com"})
      {:ok, _} = Accounts.save_openai_api_key(second_su, "sk-openai-second")

      assert is_nil(Accounts.openai_credentials_for_user(chat_user.id))
    end
  end

  describe "openai_key_for_user/1 cross-channel fallback" do
    setup do
      {:ok, chat_user} =
        %Assistant.Schemas.User{}
        |> Assistant.Schemas.User.changeset(%{
          external_id: "tg-#{System.unique_integer([:positive])}",
          channel: "telegram"
        })
        |> Repo.insert()

      {:ok, pseudo_user} =
        %Assistant.Schemas.User{}
        |> Assistant.Schemas.User.changeset(%{
          external_id: "settings:pseudo-#{System.unique_integer([:positive])}",
          channel: "settings"
        })
        |> Repo.insert()

      settings_user = settings_user_fixture()

      settings_user =
        settings_user
        |> Ecto.Changeset.change(%{user_id: pseudo_user.id})
        |> Repo.update!()

      %{chat_user: chat_user, settings_user: settings_user}
    end

    test "falls back to sole settings_user key when direct lookup fails", %{
      chat_user: chat_user,
      settings_user: settings_user
    } do
      {:ok, _} = Accounts.save_openai_api_key(settings_user, "sk-openai-key-fallback")

      assert Accounts.openai_key_for_user(chat_user.id) == "sk-openai-key-fallback"
    end
  end

  describe "ensure_linked_user/1 auto-link" do
    test "auto-links to existing chat user by email match" do
      email = "autolink-#{System.unique_integer([:positive])}@example.com"

      # Create a real chat user with matching email
      {:ok, chat_user} =
        %Assistant.Schemas.User{}
        |> Assistant.Schemas.User.changeset(%{
          external_id: "tg-autolink-#{System.unique_integer([:positive])}",
          channel: "telegram",
          email: String.downcase(email)
        })
        |> Repo.insert()

      # Create an unlinked settings_user (user_id = nil) with matching email
      settings_user = settings_user_fixture(%{email: email})
      assert is_nil(settings_user.user_id)

      # ensure_linked_user should auto-link via email match
      assert {:ok, linked_user_id} =
               AssistantWeb.SettingsLive.Context.ensure_linked_user(settings_user)

      assert linked_user_id == chat_user.id

      # Verify the settings_user was actually updated in DB
      reloaded = Repo.get!(SettingsUser, settings_user.id)
      assert reloaded.user_id == chat_user.id
    end

    test "upgrades pseudo-user to real user by email match" do
      email = "repair-#{System.unique_integer([:positive])}@example.com"

      {:ok, chat_user} =
        %Assistant.Schemas.User{}
        |> Assistant.Schemas.User.changeset(%{
          external_id: "tg-repair-#{System.unique_integer([:positive])}",
          channel: "telegram",
          email: String.downcase(email)
        })
        |> Repo.insert()

      {:ok, pseudo_user} =
        %Assistant.Schemas.User{}
        |> Assistant.Schemas.User.changeset(%{
          external_id: "settings:repair-#{System.unique_integer([:positive])}",
          channel: "settings"
        })
        |> Repo.insert()

      settings_user =
        settings_user_fixture(%{email: email})
        |> Ecto.Changeset.change(%{user_id: pseudo_user.id})
        |> Repo.update!()

      assert {:ok, linked_user_id} =
               AssistantWeb.SettingsLive.Context.ensure_linked_user(settings_user)

      # Should upgrade to the real chat user via email match
      assert linked_user_id == chat_user.id

      reloaded = Repo.get!(SettingsUser, settings_user.id)
      assert reloaded.user_id == chat_user.id
    end

    test "creates pseudo-user when multiple chat users exist" do
      {:ok, _chat_user1} =
        %Assistant.Schemas.User{}
        |> Assistant.Schemas.User.changeset(%{
          external_id: "tg-multi1-#{System.unique_integer([:positive])}",
          channel: "telegram"
        })
        |> Repo.insert()

      {:ok, _chat_user2} =
        %Assistant.Schemas.User{}
        |> Assistant.Schemas.User.changeset(%{
          external_id: "gc-multi2-#{System.unique_integer([:positive])}",
          channel: "google_chat"
        })
        |> Repo.insert()

      settings_user = settings_user_fixture()

      assert {:ok, linked_user_id} =
               AssistantWeb.SettingsLive.Context.ensure_linked_user(settings_user)

      # Should have created a pseudo-user, not linked to either real user
      pseudo = Repo.get!(Assistant.Schemas.User, linked_user_id)
      assert pseudo.channel == "settings"
    end

    test "keeps existing pseudo-user link when multiple real chat users exist" do
      {:ok, _chat_user1} =
        %Assistant.Schemas.User{}
        |> Assistant.Schemas.User.changeset(%{
          external_id: "tg-keep-pseudo-#{System.unique_integer([:positive])}",
          channel: "telegram"
        })
        |> Repo.insert()

      {:ok, _chat_user2} =
        %Assistant.Schemas.User{}
        |> Assistant.Schemas.User.changeset(%{
          external_id: "gc-keep-pseudo-#{System.unique_integer([:positive])}",
          channel: "google_chat"
        })
        |> Repo.insert()

      {:ok, pseudo_user} =
        %Assistant.Schemas.User{}
        |> Assistant.Schemas.User.changeset(%{
          external_id: "settings:keep-#{System.unique_integer([:positive])}",
          channel: "settings"
        })
        |> Repo.insert()

      settings_user =
        settings_user_fixture()
        |> Ecto.Changeset.change(%{user_id: pseudo_user.id})
        |> Repo.update!()

      assert {:ok, linked_user_id} =
               AssistantWeb.SettingsLive.Context.ensure_linked_user(settings_user)

      assert linked_user_id == pseudo_user.id

      reloaded = Repo.get!(SettingsUser, settings_user.id)
      assert reloaded.user_id == pseudo_user.id
    end
  end

  describe "sole_settings_user_key multi-admin ambiguity" do
    test "returns nil when 2+ settings_users have OpenRouter keys" do
      su1 = settings_user_fixture(%{email: "admin1@example.com"})
      su2 = settings_user_fixture(%{email: "admin2@example.com"})

      {:ok, _} = Accounts.save_openrouter_api_key(su1, "sk-or-admin1")
      {:ok, _} = Accounts.save_openrouter_api_key(su2, "sk-or-admin2")

      # With multiple keyed settings_users, the bridge must return nil
      assert is_nil(Assistant.Accounts.CrossChannelBridge.sole_key(:openrouter_api_key))
    end

    test "returns nil when 2+ settings_users have OpenAI keys" do
      su1 = settings_user_fixture(%{email: "ai-admin1@example.com"})
      su2 = settings_user_fixture(%{email: "ai-admin2@example.com"})

      {:ok, _} = Accounts.save_openai_api_key(su1, "sk-openai-admin1")
      {:ok, _} = Accounts.save_openai_api_key(su2, "sk-openai-admin2")

      assert is_nil(Assistant.Accounts.CrossChannelBridge.sole_key(:openai_api_key))
    end
  end

  describe "openai_credentials_for_user/1 fallback path" do
    setup do
      {:ok, chat_user} =
        %Assistant.Schemas.User{}
        |> Assistant.Schemas.User.changeset(%{
          external_id: "tg-cred-fallback-#{System.unique_integer([:positive])}",
          channel: "telegram"
        })
        |> Repo.insert()

      {:ok, pseudo_user} =
        %Assistant.Schemas.User{}
        |> Assistant.Schemas.User.changeset(%{
          external_id: "settings:cred-pseudo-#{System.unique_integer([:positive])}",
          channel: "settings"
        })
        |> Repo.insert()

      settings_user = settings_user_fixture()

      settings_user =
        settings_user
        |> Ecto.Changeset.change(%{user_id: pseudo_user.id})
        |> Repo.update!()

      %{chat_user: chat_user, settings_user: settings_user}
    end

    test "falls back to sole credentials with auth_type when direct lookup fails", %{
      chat_user: chat_user,
      settings_user: settings_user
    } do
      # Store OpenAI OAuth credentials (not just an API key).
      # save_openai_oauth_credentials uses openai_oauth_changeset which
      # expects :access_token, :refresh_token, etc. (not openai_*-prefixed).
      {:ok, _} =
        Accounts.save_openai_oauth_credentials(settings_user, %{
          access_token: "sk-openai-oauth-token",
          refresh_token: "rt-refresh",
          account_id: "acct-123"
        })

      result = Accounts.openai_credentials_for_user(chat_user.id)
      assert result.access_token == "sk-openai-oauth-token"
      assert result.auth_type == "oauth"
      assert result.refresh_token == "rt-refresh"
      assert result.account_id == "acct-123"
    end

    test "returns nil for invalid user_id" do
      assert is_nil(Accounts.openai_credentials_for_user("not-a-uuid"))
    end

    test "returns nil for non-binary input" do
      assert is_nil(Accounts.openai_credentials_for_user(nil))
      assert is_nil(Accounts.openai_credentials_for_user(123))
    end
  end

  describe "inspect/2 for the SettingsUser module" do
    test "does not include password" do
      refute inspect(%SettingsUser{password: "123456"}) =~ "password: \"123456\""
    end
  end
end

defmodule Assistant.AccountsTest do
  use Assistant.DataCase

  alias Assistant.Accounts

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
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
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

      assert {:ok, {^settings_user, []}} =
               Accounts.login_settings_user_by_magic_link(encoded_token)

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

  describe "inspect/2 for the SettingsUser module" do
    test "does not include password" do
      refute inspect(%SettingsUser{password: "123456"}) =~ "password: \"123456\""
    end
  end
end

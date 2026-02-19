defmodule Assistant.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Assistant.Accounts` context.
  """

  import Ecto.Query

  alias Assistant.Accounts
  alias Assistant.Accounts.Scope

  def unique_settings_user_email, do: "settings_user#{System.unique_integer()}@example.com"
  def valid_settings_user_password, do: "hello world!"

  def valid_settings_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_settings_user_email()
    })
  end

  def unconfirmed_settings_user_fixture(attrs \\ %{}) do
    {:ok, settings_user} =
      attrs
      |> valid_settings_user_attributes()
      |> Accounts.register_settings_user()

    settings_user
  end

  def settings_user_fixture(attrs \\ %{}) do
    settings_user = unconfirmed_settings_user_fixture(attrs)

    token =
      extract_settings_user_token(fn url ->
        Accounts.deliver_login_instructions(settings_user, url)
      end)

    {:ok, {settings_user, _expired_tokens}} =
      Accounts.login_settings_user_by_magic_link(token)

    settings_user
  end

  def settings_user_scope_fixture do
    settings_user = settings_user_fixture()
    settings_user_scope_fixture(settings_user)
  end

  def settings_user_scope_fixture(settings_user) do
    Scope.for_settings_user(settings_user)
  end

  def set_password(settings_user) do
    {:ok, {settings_user, _expired_tokens}} =
      Accounts.update_settings_user_password(settings_user, %{
        password: valid_settings_user_password()
      })

    settings_user
  end

  def extract_settings_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    Assistant.Repo.update_all(
      from(t in Accounts.SettingsUserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_settings_user_magic_link_token(settings_user) do
    {encoded_token, settings_user_token} =
      Accounts.SettingsUserToken.build_email_token(settings_user, "login")

    Assistant.Repo.insert!(settings_user_token)
    {encoded_token, settings_user_token.token}
  end

  def offset_settings_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    Assistant.Repo.update_all(
      from(ut in Accounts.SettingsUserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end

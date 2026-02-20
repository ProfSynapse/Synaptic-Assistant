# test/support/conn_case.ex — Controller test case template.
#
# Provides setup for tests that require a Phoenix connection.
# Sets up the Ecto sandbox and builds a test connection.

defmodule AssistantWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use AssistantWeb.ConnCase, async: true`, although
  this option is not recommended for heavy database use.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint AssistantWeb.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest

      import AssistantWeb.ConnCase

      use AssistantWeb, :verified_routes
    end
  end

  setup tags do
    Assistant.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Setup helper that registers and logs in settings_users.

      setup :register_and_log_in_settings_user

  It stores an updated connection and a registered settings_user in the
  test context.
  """
  def register_and_log_in_settings_user(%{conn: conn} = context) do
    settings_user = Assistant.AccountsFixtures.settings_user_fixture()
    scope = Assistant.Accounts.Scope.for_settings_user(settings_user)

    opts =
      context
      |> Map.take([:token_authenticated_at])
      |> Enum.into([])

    %{
      conn: log_in_settings_user(conn, settings_user, opts),
      settings_user: settings_user,
      scope: scope
    }
  end

  @doc """
  Logs the given `settings_user` into the `conn`.

  It returns an updated `conn`.
  """
  def log_in_settings_user(conn, settings_user, opts \\ []) do
    token = Assistant.Accounts.generate_settings_user_session_token(settings_user)

    maybe_set_token_authenticated_at(token, opts[:token_authenticated_at])

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:settings_user_token, token)
  end

  defp maybe_set_token_authenticated_at(_token, nil), do: nil

  defp maybe_set_token_authenticated_at(token, authenticated_at) do
    Assistant.AccountsFixtures.override_token_authenticated_at(token, authenticated_at)
  end
end

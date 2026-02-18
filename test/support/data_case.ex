# test/support/data_case.ex — Database test case template.
#
# Provides setup for tests that require database access.
# Uses Ecto SQL Sandbox for isolation between async tests.

defmodule Assistant.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Assistant.DataCase, async: true`, although
  this option is not recommended for heavy database use.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Assistant.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Assistant.DataCase
    end
  end

  setup tags do
    Assistant.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Assistant.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "should be at least 12 character(s)" in errors_on(changeset).password
      assert %{password: ["should be at least 12 character(s)"]} = errors_on(changeset)
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end

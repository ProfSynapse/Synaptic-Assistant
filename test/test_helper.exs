# test/test_helper.exs — Test initialization.
#
# Starts ExUnit and configures the Ecto sandbox for async tests.

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Assistant.Repo, :manual)

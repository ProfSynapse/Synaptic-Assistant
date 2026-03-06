defmodule AssistantWeb.SettingsUserAuthScopeTest do
  @moduledoc """
  Tests for the on_mount({:require_scope, scope_name}, ...) hook in SettingsUserAuth.

  Covers all 5 branches:
    1. Unauthenticated user -> redirect to login
    2. Admin user -> always passes regardless of scope
    3. User with empty privileges (no scopes) -> passes (backwards compat)
    4. User with matching scope -> passes
    5. User without matching scope -> redirect with "Access denied."
  """
  use AssistantWeb.ConnCase, async: false

  import Assistant.AccountsFixtures

  alias Assistant.Accounts

  # --- Helpers ---

  defp build_socket(session) do
    %Phoenix.LiveView.Socket{
      endpoint: AssistantWeb.Endpoint,
      assigns: %{__changed__: %{}, flash: %{}},
      private: %{
        lifecycle: %Phoenix.LiveView.Lifecycle{
          handle_info: [],
          handle_event: [],
          handle_params: [],
          handle_async: [],
          after_render: []
        },
        assign_new: {%{}, %{}},
        live_temp: %{}
      }
    }
    |> then(fn socket ->
      AssistantWeb.SettingsUserAuth.on_mount(
        {:require_scope, "test_scope"},
        %{},
        session,
        socket
      )
    end)
  end

  defp session_for_user(user) do
    token = Accounts.generate_settings_user_session_token(user)
    %{"settings_user_token" => token}
  end

  defp create_user_with_scopes(scopes, opts \\ []) do
    user = settings_user_fixture()
    is_admin = Keyword.get(opts, :is_admin, false)

    user
    |> Ecto.Changeset.change(access_scopes: scopes, is_admin: is_admin)
    |> Assistant.Repo.update!()
  end

  # --- Tests ---

  describe "on_mount {:require_scope, scope_name}" do
    test "redirects unauthenticated user to login" do
      result = build_socket(%{})

      assert {:halt, socket} = result
      assert {:redirect, %{to: "/settings_users/log-in"}} = socket.redirected
    end

    test "admin user always passes regardless of scope" do
      admin = create_user_with_scopes([], is_admin: true)
      session = session_for_user(admin)

      result = build_socket(session)

      assert {:cont, socket} = result
      assert socket.assigns.current_scope.admin?
    end

    test "user with empty privileges passes (backwards compat)" do
      user = create_user_with_scopes([])
      session = session_for_user(user)

      result = build_socket(session)

      assert {:cont, socket} = result
      refute socket.assigns.current_scope.admin?
      assert socket.assigns.current_scope.privileges == []
    end

    test "user with matching scope in privileges passes" do
      user = create_user_with_scopes(["test_scope", "other_scope"])
      session = session_for_user(user)

      result = build_socket(session)

      assert {:cont, socket} = result
      assert "test_scope" in socket.assigns.current_scope.privileges
    end

    test "user without matching scope is redirected with Access denied" do
      user = create_user_with_scopes(["chat", "integrations"])
      session = session_for_user(user)

      result = build_socket(session)

      assert {:halt, socket} = result
      assert {:redirect, %{to: "/"}} = socket.redirected
    end
  end
end

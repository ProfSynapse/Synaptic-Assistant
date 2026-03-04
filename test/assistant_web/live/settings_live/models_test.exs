defmodule AssistantWeb.SettingsLive.ModelsTest do
  use AssistantWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Assistant.Accounts
  alias Assistant.IntegrationSettings
  alias Assistant.IntegrationSettings.Cache
  alias Assistant.Repo

  import Assistant.AccountsFixtures

  @model_default_keys [
    :model_default_orchestrator,
    :model_default_sub_agent,
    :model_default_sentinel,
    :model_default_compaction
  ]

  setup do
    Enum.each(@model_default_keys, &IntegrationSettings.delete/1)
    Cache.invalidate_all()

    on_exit(fn ->
      Enum.each(@model_default_keys, &IntegrationSettings.delete/1)
      Cache.invalidate_all()
    end)

    :ok
  end

  test "admin role defaults auto-save globally and persist across remounts", %{conn: conn} do
    admin = admin_settings_user()
    conn = log_in_settings_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/settings/models")

    html = render(lv)
    assert html =~ "app-wide default model"
    assert html =~ "Changes save automatically."

    render_change(lv, "change_model_defaults", %{
      "defaults" => %{"orchestrator" => "openai/gpt-5.2"}
    })

    settle_cache()
    assert IntegrationSettings.get(:model_default_orchestrator) == "openai/gpt-5.2"

    {:ok, lv, _html} = live(conn, ~p"/settings/models")

    select_html =
      lv
      |> element(~s(select[name="defaults[orchestrator]"]))
      |> render()

    assert select_html =~
             ~r/<option[^>]*(selected[^>]*value="openai\/gpt-5\.2"|value="openai\/gpt-5\.2"[^>]*selected)/
  end

  test "permitted user auto-saves personal overrides without copying untouched global defaults",
       %{
         conn: conn
       } do
    admin = admin_settings_user()
    {:ok, _} = IntegrationSettings.put(:model_default_orchestrator, "openai/gpt-5-mini", admin.id)
    {:ok, _} = IntegrationSettings.put(:model_default_sub_agent, "openai/gpt-5-mini", admin.id)
    settle_cache()

    user = allowlisted_settings_user(%{email: "models-user@example.com"})
    {:ok, _user} = Accounts.toggle_user_model_defaults_access(user.id, true)

    conn = log_in_settings_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/settings/models")

    html = render(lv)
    assert html =~ "personal model overrides"

    render_change(lv, "change_model_defaults", %{
      "defaults" => %{"orchestrator" => "openai/gpt-5.2", "sub_agent" => "openai/gpt-5-mini"}
    })

    reloaded_user = Accounts.get_settings_user!(user.id)

    assert reloaded_user.model_defaults == %{"orchestrator" => "openai/gpt-5.2"}

    assert Assistant.ModelDefaults.default_model_id(:orchestrator, settings_user: reloaded_user) ==
             "openai/gpt-5.2"

    {:ok, lv, _html} = live(conn, ~p"/settings/models")

    select_html =
      lv
      |> element(~s(select[name="defaults[orchestrator]"]))
      |> render()

    assert select_html =~
             ~r/<option[^>]*(selected[^>]*value="openai\/gpt-5\.2"|value="openai\/gpt-5\.2"[^>]*selected)/
  end

  test "user without permission sees admin-managed overrides as read-only and cannot save overrides",
       %{
         conn: conn
       } do
    admin = admin_settings_user()
    {:ok, _} = IntegrationSettings.put(:model_default_orchestrator, "openai/gpt-5-mini", admin.id)
    settle_cache()

    user =
      allowlisted_settings_user(%{
        email: "readonly-models@example.com",
        model_defaults: %{"orchestrator" => "openai/gpt-5.2"}
      })

    conn = log_in_settings_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/settings/models")

    html = render(lv)
    assert html =~ "Managed by your admin."
    assert html =~ "Admin override"

    select_html =
      lv
      |> element(~s(select[name="defaults[orchestrator]"]))
      |> render()

    assert select_html =~ "disabled"

    html =
      render_change(lv, "change_model_defaults", %{
        "defaults" => %{"orchestrator" => "openai/gpt-5.2"}
      })

    assert html =~ "do not have permission to update model defaults"
    assert IntegrationSettings.get(:model_default_orchestrator) == "openai/gpt-5-mini"

    assert Accounts.get_settings_user!(user.id).model_defaults == %{
             "orchestrator" => "openai/gpt-5.2"
           }

    assert Assistant.ModelDefaults.default_model_id(
             :orchestrator,
             settings_user: Accounts.get_settings_user!(user.id)
           ) == "openai/gpt-5.2"
  end

  defp admin_settings_user(attrs \\ %{}) do
    admin = settings_user_fixture(attrs)
    {:ok, admin} = Accounts.bootstrap_admin_access(admin)
    admin
  end

  defp settle_cache do
    Process.sleep(50)
    Cache.warm()
  end

  defp allowlisted_settings_user(attrs) do
    email = attrs[:email] || unique_settings_user_email()

    Accounts.upsert_settings_user_allowlist_entry(
      %{email: email, active: true, is_admin: false, scopes: []},
      nil,
      transaction?: false
    )

    user =
      attrs
      |> Map.new()
      |> Map.put(:email, email)
      |> Map.take([:email])
      |> settings_user_fixture()

    update_attrs =
      attrs
      |> Map.new()
      |> Map.take([:model_defaults, :can_manage_model_defaults])

    if map_size(update_attrs) == 0 do
      user
    else
      user
      |> Ecto.Changeset.change(update_attrs)
      |> Repo.update!()
    end
  end
end

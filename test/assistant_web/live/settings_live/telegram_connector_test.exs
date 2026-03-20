defmodule AssistantWeb.SettingsLive.TelegramConnectorTest do
  use AssistantWeb.ConnCase, async: false
  @moduletag :external

  import Phoenix.LiveViewTest

  alias Assistant.Accounts
  alias Assistant.IntegrationSettings.Cache

  import Assistant.AccountsFixtures

  @bot_token "telegram-settings-test-token"

  setup do
    bypass = Bypass.open()
    prev_token = Application.get_env(:assistant, :telegram_bot_token)
    prev_secret = Application.get_env(:assistant, :telegram_webhook_secret)
    prev_base_url = Application.get_env(:assistant, :telegram_api_base_url)

    Cache.invalidate(:telegram_bot_token)
    Application.delete_env(:assistant, :telegram_bot_token)
    Application.delete_env(:assistant, :telegram_webhook_secret)
    Application.put_env(:assistant, :telegram_api_base_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      Cache.invalidate(:telegram_bot_token)

      if prev_token,
        do: Application.put_env(:assistant, :telegram_bot_token, prev_token),
        else: Application.delete_env(:assistant, :telegram_bot_token)

      if prev_secret,
        do: Application.put_env(:assistant, :telegram_webhook_secret, prev_secret),
        else: Application.delete_env(:assistant, :telegram_webhook_secret)

      if prev_base_url,
        do: Application.put_env(:assistant, :telegram_api_base_url, prev_base_url),
        else: Application.delete_env(:assistant, :telegram_api_base_url)
    end)

    %{bypass: bypass}
  end

  test "configured Telegram credentials allow generating a one-time connect link", %{
    conn: conn,
    bypass: bypass
  } do
    settings_user = admin_settings_user_fixture(%{email: unique_settings_user_email()})

    Bypass.expect(bypass, "GET", "/bot#{@bot_token}/getMe", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "result" => %{
            "id" => 123,
            "is_bot" => true,
            "username" => "synaptic_test_bot",
            "first_name" => "Synaptic"
          }
        })
      )
    end)

    conn = log_in_settings_user(conn, settings_user)
    Cache.invalidate(:telegram_bot_token)
    Application.put_env(:assistant, :telegram_bot_token, @bot_token)

    {:ok, lv, _html} = live(conn, ~p"/settings/apps/telegram")
    _ = render_click(element(lv, "button[phx-click=\"generate_telegram_connect_link\"]"))
    html = render(lv)

    assert has_element?(lv, "a[href^=\"https://t.me/synaptic_test_bot?start=\"]")
    assert html =~ "Only linked Telegram accounts can chat with this bot."

    reloaded = Accounts.get_settings_user!(settings_user.id)
    assert is_binary(reloaded.user_id)
  end

  test "apps card toggle redirects to telegram settings when user is not linked", %{
    conn: conn,
    bypass: bypass
  } do
    settings_user = settings_user_fixture(%{email: unique_settings_user_email()})

    Cache.invalidate(:telegram_bot_token)
    Application.put_env(:assistant, :telegram_bot_token, @bot_token)

    # Non-admin users get lightweight connection status (no real API calls),
    # so stub instead of expect — the getMe endpoint may not be called.
    Bypass.stub(bypass, "GET", "/bot#{@bot_token}/getMe", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "ok" => true,
          "result" => %{
            "id" => 123,
            "is_bot" => true,
            "username" => "synaptic_test_bot",
            "first_name" => "Synaptic"
          }
        })
      )
    end)

    conn = log_in_settings_user(conn, settings_user)
    {:ok, lv, _html} = live(conn, ~p"/settings/apps")

    _ =
      lv
      |> element("input[phx-click=\"toggle_connector\"][phx-value-app_id=\"telegram\"]")
      |> render_click()

    assert_redirect(lv, ~p"/settings/apps/telegram")
  end
end

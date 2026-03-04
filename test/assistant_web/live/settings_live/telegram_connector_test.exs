defmodule AssistantWeb.SettingsLive.TelegramConnectorTest do
  use AssistantWeb.ConnCase, async: false

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

  test "saving a Telegram bot token generates a one-time connect link", %{
    conn: conn,
    bypass: bypass
  } do
    settings_user = admin_settings_user_fixture(%{email: unique_settings_user_email()})

    Bypass.expect_once(bypass, "GET", "/bot#{@bot_token}/getMe", fn conn ->
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
    {:ok, lv, _html} = live(conn, ~p"/settings/apps/telegram")

    lv
    |> form("#form-telegram_bot_token", %{"key" => "telegram_bot_token", "value" => @bot_token})
    |> render_submit()

    html = render(lv)

    assert has_element?(lv, "a[href^=\"https://t.me/synaptic_test_bot?start=\"]")
    assert html =~ "Only linked Telegram accounts can chat with this bot."

    reloaded = Accounts.get_settings_user!(settings_user.id)
    assert is_binary(reloaded.user_id)
  end
end

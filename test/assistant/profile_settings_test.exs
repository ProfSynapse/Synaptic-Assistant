defmodule Assistant.ProfileSettingsTest do
  use ExUnit.Case, async: false

  alias Assistant.ProfileSettings

  setup do
    original = Application.get_env(:assistant, :profile_settings_path)

    path =
      Path.join(
        System.tmp_dir!(),
        "profile_settings_test_#{System.unique_integer([:positive])}.json"
      )

    File.rm(path)
    Application.put_env(:assistant, :profile_settings_path, path)

    on_exit(fn ->
      File.rm(path)

      if original do
        Application.put_env(:assistant, :profile_settings_path, original)
      else
        Application.delete_env(:assistant, :profile_settings_path)
      end
    end)

    {:ok, path: path}
  end

  test "get_profile/0 returns defaults when file is missing" do
    assert ProfileSettings.get_profile() == %{
             "display_name" => "",
             "email" => "",
             "timezone" => "UTC"
           }
  end

  test "save_profile/1 persists sanitized fields and get_profile/0 loads them" do
    assert :ok =
             ProfileSettings.save_profile(%{
               "display_name" => "  Jane Doe ",
               "email" => " jane@example.com ",
               "timezone" => " America/New_York "
             })

    assert ProfileSettings.get_profile() == %{
             "display_name" => "Jane Doe",
             "email" => "jane@example.com",
             "timezone" => "America/New_York"
           }
  end
end

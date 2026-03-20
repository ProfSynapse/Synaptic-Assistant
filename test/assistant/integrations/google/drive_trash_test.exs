defmodule Assistant.Integrations.Google.DriveTrashTest do
  use ExUnit.Case, async: true
  @moduletag :external

  alias Assistant.Integrations.Google.Drive

  test "trash_file returns an error for an invalid token" do
    assert {:error, _reason} = Drive.trash_file("invalid-token", "file-id")
  end
end

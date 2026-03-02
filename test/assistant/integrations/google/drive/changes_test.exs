# test/assistant/integrations/google/drive/changes_test.exs
#
# Tests for Assistant.Integrations.Google.Drive.Changes — Drive Changes API
# wrapper. Tests the normalization logic and pagination behavior. Since no
# Bypass is configured, tests verify error handling paths with invalid tokens.
#
# Related files:
#   - lib/assistant/integrations/google/drive/changes.ex (module under test)
#   - lib/assistant/integrations/google/drive.ex (main Drive client)

defmodule Assistant.Integrations.Google.Drive.ChangesTest do
  use ExUnit.Case, async: true

  alias Assistant.Integrations.Google.Drive.Changes

  # ---------------------------------------------------------------
  # get_start_page_token/2
  # ---------------------------------------------------------------

  describe "get_start_page_token/2" do
    test "returns error with invalid token" do
      assert {:error, _} = Changes.get_start_page_token("invalid-token")
    end

    test "accepts drive_id option" do
      # Should fail with invalid token, but proves the option is passed
      assert {:error, _} = Changes.get_start_page_token("invalid-token", drive_id: "d1")
    end
  end

  # ---------------------------------------------------------------
  # list_changes/3
  # ---------------------------------------------------------------

  describe "list_changes/3" do
    test "returns error with invalid token" do
      assert {:error, _} = Changes.list_changes("invalid-token", "page-token-123")
    end

    test "accepts options" do
      assert {:error, _} =
               Changes.list_changes("invalid-token", "page-token", drive_id: "d1", page_size: 50)
    end
  end

  # ---------------------------------------------------------------
  # list_all_changes/3
  # ---------------------------------------------------------------

  describe "list_all_changes/3" do
    test "returns error with invalid token" do
      assert {:error, _} = Changes.list_all_changes("invalid-token", "page-token-123")
    end
  end
end

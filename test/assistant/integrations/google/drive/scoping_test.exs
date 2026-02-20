# test/assistant/integrations/google/drive/scoping_test.exs
#
# Tests for Drive.Scoping — pure function that builds Google Drive API
# query parameters from a list of enabled drives. No DB or HTTP needed.
#
# Related files:
#   - lib/assistant/integrations/google/drive/scoping.ex (module under test)

defmodule Assistant.Integrations.Google.Drive.ScopingTest do
  use ExUnit.Case, async: true

  alias Assistant.Integrations.Google.Drive.Scoping

  # ---------------------------------------------------------------
  # build_query_params/1
  # ---------------------------------------------------------------

  describe "build_query_params/1" do
    test "returns error when no drives are enabled" do
      assert {:error, :no_drives_enabled} = Scoping.build_query_params([])
    end

    test "returns single user scope for personal drive only" do
      drives = [%{drive_id: nil, drive_type: "personal"}]

      assert {:ok, [params]} = Scoping.build_query_params(drives)
      assert params[:corpora] == "user"
      assert params[:supportsAllDrives] == true
      refute Keyword.has_key?(params, :driveId)
      refute Keyword.has_key?(params, :includeItemsFromAllDrives)
    end

    test "returns single drive scope for a single shared drive" do
      drives = [%{drive_id: "drive-abc", drive_type: "shared"}]

      assert {:ok, [params]} = Scoping.build_query_params(drives)
      assert params[:corpora] == "drive"
      assert params[:driveId] == "drive-abc"
      assert params[:includeItemsFromAllDrives] == true
      assert params[:supportsAllDrives] == true
    end

    test "returns personal + shared scopes for personal + one shared drive" do
      drives = [
        %{drive_id: nil, drive_type: "personal"},
        %{drive_id: "drive-xyz", drive_type: "shared"}
      ]

      assert {:ok, scopes} = Scoping.build_query_params(drives)
      assert length(scopes) == 2

      [personal, shared] = scopes
      assert personal[:corpora] == "user"
      assert shared[:corpora] == "drive"
      assert shared[:driveId] == "drive-xyz"
    end

    test "returns one scope per shared drive for multiple shared drives" do
      drives = [
        %{drive_id: "drive-1", drive_type: "shared"},
        %{drive_id: "drive-2", drive_type: "shared"}
      ]

      assert {:ok, scopes} = Scoping.build_query_params(drives)
      assert length(scopes) == 2

      [scope_1, scope_2] = scopes
      assert scope_1[:corpora] == "drive"
      assert scope_1[:driveId] == "drive-1"
      assert scope_2[:corpora] == "drive"
      assert scope_2[:driveId] == "drive-2"
    end

    test "returns personal + per-drive scopes for personal + multiple shared drives" do
      drives = [
        %{drive_id: nil, drive_type: "personal"},
        %{drive_id: "drive-a", drive_type: "shared"},
        %{drive_id: "drive-b", drive_type: "shared"}
      ]

      assert {:ok, scopes} = Scoping.build_query_params(drives)
      assert length(scopes) == 3

      [personal | shared_scopes] = scopes
      assert personal[:corpora] == "user"

      drive_ids = Enum.map(shared_scopes, & &1[:driveId])
      assert "drive-a" in drive_ids
      assert "drive-b" in drive_ids
    end

    test "all shared drive scopes include required flags" do
      drives = [%{drive_id: "drive-x", drive_type: "shared"}]

      assert {:ok, [params]} = Scoping.build_query_params(drives)
      assert params[:includeItemsFromAllDrives] == true
      assert params[:supportsAllDrives] == true
    end
  end
end

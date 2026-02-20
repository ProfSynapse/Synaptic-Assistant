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

    test "returns corpora: user for personal drive only" do
      drives = [%{drive_id: nil, drive_type: "personal"}]

      assert {:ok, params} = Scoping.build_query_params(drives)
      assert params[:corpora] == "user"
      assert params[:supportsAllDrives] == true
      refute Keyword.has_key?(params, :driveId)
      refute Keyword.has_key?(params, :includeItemsFromAllDrives)
    end

    test "returns corpora: drive for a single shared drive" do
      drives = [%{drive_id: "drive-abc", drive_type: "shared"}]

      assert {:ok, params} = Scoping.build_query_params(drives)
      assert params[:corpora] == "drive"
      assert params[:driveId] == "drive-abc"
      assert params[:includeItemsFromAllDrives] == true
      assert params[:supportsAllDrives] == true
    end

    test "returns corpora: allDrives for personal + shared drives" do
      drives = [
        %{drive_id: nil, drive_type: "personal"},
        %{drive_id: "drive-xyz", drive_type: "shared"}
      ]

      assert {:ok, params} = Scoping.build_query_params(drives)
      assert params[:corpora] == "allDrives"
      assert params[:includeItemsFromAllDrives] == true
      assert params[:supportsAllDrives] == true
      refute Keyword.has_key?(params, :driveId)
    end

    test "returns corpora: allDrives for multiple shared drives" do
      drives = [
        %{drive_id: "drive-1", drive_type: "shared"},
        %{drive_id: "drive-2", drive_type: "shared"}
      ]

      assert {:ok, params} = Scoping.build_query_params(drives)
      assert params[:corpora] == "allDrives"
      assert params[:includeItemsFromAllDrives] == true
      assert params[:supportsAllDrives] == true
    end

    test "returns corpora: allDrives for personal + multiple shared drives" do
      drives = [
        %{drive_id: nil, drive_type: "personal"},
        %{drive_id: "drive-a", drive_type: "shared"},
        %{drive_id: "drive-b", drive_type: "shared"}
      ]

      assert {:ok, params} = Scoping.build_query_params(drives)
      assert params[:corpora] == "allDrives"
    end
  end
end

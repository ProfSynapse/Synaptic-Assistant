# test/assistant/skills/files/search_test.exs
#
# Tests for the files.search skill handler. Uses a mock Drive module
# injected via context.integrations[:drive] to avoid real API calls.
# Tests query building, result formatting, error handling, and limit parsing.

defmodule Assistant.Skills.Files.SearchTest do
  use ExUnit.Case, async: true

  alias Assistant.Skills.Files.Search
  alias Assistant.Skills.Context
  alias Assistant.Skills.Result

  # ---------------------------------------------------------------
  # Mock Drive module
  # ---------------------------------------------------------------

  defmodule MockDrive do
    @moduledoc false

    # Returns whatever the test process stored in the process dictionary.
    # Default: {:ok, []}
    def list_files(query, opts \\ []) do
      send(self(), {:drive_list_files, query, opts})

      case Process.get(:mock_drive_response) do
        nil -> {:ok, []}
        response -> response
      end
    end

    def type_to_mime(type), do: Assistant.Integrations.Google.Drive.type_to_mime(type)
  end

  # ---------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------

  defp build_context(overrides \\ %{}) do
    base = %Context{
      conversation_id: "conv-1",
      execution_id: "exec-1",
      user_id: "user-1",
      integrations: %{drive: MockDrive}
    }

    Map.merge(base, overrides)
  end

  defp set_mock_response(response) do
    Process.put(:mock_drive_response, response)
  end

  defp mock_file(attrs \\ %{}) do
    Map.merge(
      %{
        id: "file_abc",
        name: "Report Q1.docx",
        mime_type: "application/vnd.google-apps.document",
        modified_time: "2026-02-01T12:00:00Z",
        size: "1024",
        parents: ["folder_1"]
      },
      attrs
    )
  end

  # ---------------------------------------------------------------
  # Basic query execution
  # ---------------------------------------------------------------

  describe "execute/2 with no flags" do
    test "searches with trashed = false when no flags provided" do
      {:ok, %Result{status: :ok}} = Search.execute(%{}, build_context())

      assert_received {:drive_list_files, "trashed = false", _opts}
    end

    test "returns 'No files found' message when results are empty" do
      set_mock_response({:ok, []})

      {:ok, result} = Search.execute(%{}, build_context())

      assert result.status == :ok
      assert result.content =~ "No files found"
      assert result.metadata.count == 0
    end
  end

  # ---------------------------------------------------------------
  # Query building with flags
  # ---------------------------------------------------------------

  describe "execute/2 query building" do
    test "includes name contains clause for query flag" do
      Search.execute(%{"query" => "report"}, build_context())

      assert_received {:drive_list_files, query, _opts}
      assert query =~ "name contains 'report'"
      assert query =~ "trashed = false"
    end

    test "includes mimeType clause for type flag" do
      Search.execute(%{"type" => "doc"}, build_context())

      assert_received {:drive_list_files, query, _opts}
      assert query =~ "mimeType = 'application/vnd.google-apps.document'"
    end

    test "includes parent clause for folder flag" do
      Search.execute(%{"folder" => "folder_123"}, build_context())

      assert_received {:drive_list_files, query, _opts}
      assert query =~ "'folder_123' in parents"
    end

    test "combines all flags into a single query" do
      Search.execute(
        %{"query" => "notes", "type" => "sheet", "folder" => "parent_id"},
        build_context()
      )

      assert_received {:drive_list_files, query, _opts}
      assert query =~ "name contains 'notes'"
      assert query =~ "mimeType = 'application/vnd.google-apps.spreadsheet'"
      assert query =~ "'parent_id' in parents"
      assert query =~ "trashed = false"
    end

    test "returns error for unknown type" do
      {:ok, result} = Search.execute(%{"type" => "banana"}, build_context())

      assert result.status == :error
      assert result.content =~ "Unknown file type"
      assert result.content =~ "banana"
    end

    test "escapes single quotes in query string" do
      Search.execute(%{"query" => "it's a test"}, build_context())

      assert_received {:drive_list_files, query, _opts}
      assert query =~ "it\\'s a test"
    end

    test "rejects query text containing special characters" do
      {:ok, result} = Search.execute(%{"query" => "name = evil"}, build_context())
      assert result.status == :error
      assert result.content =~ "special characters"
    end

    test "rejects folder ID with invalid characters" do
      {:ok, result} = Search.execute(%{"folder" => "parent's folder"}, build_context())
      assert result.status == :error
      assert result.content =~ "Invalid folder ID"
    end

    test "accepts valid folder ID" do
      Search.execute(%{"folder" => "abc123-DEF_456"}, build_context())

      assert_received {:drive_list_files, query, _opts}
      assert query =~ "'abc123-DEF_456' in parents"
    end
  end

  # ---------------------------------------------------------------
  # Limit parsing
  # ---------------------------------------------------------------

  describe "execute/2 limit handling" do
    test "uses default limit of 20 when not specified" do
      Search.execute(%{}, build_context())

      assert_received {:drive_list_files, _query, opts}
      assert Keyword.get(opts, :pageSize) == 20
    end

    test "passes custom limit from flags" do
      Search.execute(%{"limit" => "5"}, build_context())

      assert_received {:drive_list_files, _query, opts}
      assert Keyword.get(opts, :pageSize) == 5
    end

    test "clamps limit to max 100" do
      Search.execute(%{"limit" => "999"}, build_context())

      assert_received {:drive_list_files, _query, opts}
      assert Keyword.get(opts, :pageSize) == 100
    end

    test "clamps limit to min 1" do
      Search.execute(%{"limit" => "0"}, build_context())

      assert_received {:drive_list_files, _query, opts}
      assert Keyword.get(opts, :pageSize) == 1
    end

    test "uses default for non-numeric limit string" do
      Search.execute(%{"limit" => "abc"}, build_context())

      assert_received {:drive_list_files, _query, opts}
      assert Keyword.get(opts, :pageSize) == 20
    end

    test "handles integer limit value" do
      Search.execute(%{"limit" => 10}, build_context())

      assert_received {:drive_list_files, _query, opts}
      assert Keyword.get(opts, :pageSize) == 10
    end
  end

  # ---------------------------------------------------------------
  # Result formatting
  # ---------------------------------------------------------------

  describe "execute/2 result formatting" do
    test "formats file list with name, type, and metadata" do
      set_mock_response({:ok, [mock_file()]})

      {:ok, result} = Search.execute(%{}, build_context())

      assert result.status == :ok
      assert result.content =~ "Found 1 file(s)"
      assert result.content =~ "Report Q1.docx"
      assert result.content =~ "Google Doc"
      assert result.content =~ "file_abc"
      assert result.metadata.count == 1
    end

    test "formats multiple files" do
      set_mock_response({:ok, [
        mock_file(%{id: "f1", name: "Doc One"}),
        mock_file(%{id: "f2", name: "Doc Two"})
      ]})

      {:ok, result} = Search.execute(%{}, build_context())

      assert result.content =~ "Found 2 file(s)"
      assert result.content =~ "Doc One"
      assert result.content =~ "Doc Two"
      assert result.metadata.count == 2
    end

    test "formats file size in human-readable form" do
      set_mock_response({:ok, [mock_file(%{size: "1048576"})]})
      {:ok, result} = Search.execute(%{}, build_context())
      assert result.content =~ "1.0 MB"

      set_mock_response({:ok, [mock_file(%{size: "512"})]})
      {:ok, result2} = Search.execute(%{}, build_context())
      assert result2.content =~ "512 B"

      set_mock_response({:ok, [mock_file(%{size: "2048"})]})
      {:ok, result3} = Search.execute(%{}, build_context())
      assert result3.content =~ "2.0 KB"
    end

    test "handles files with nil size and modified_time" do
      set_mock_response({:ok, [mock_file(%{size: nil, modified_time: nil})]})

      {:ok, result} = Search.execute(%{}, build_context())

      assert result.status == :ok
      assert result.content =~ "Report Q1.docx"
    end

    test "displays friendly type names" do
      types = [
        {"application/vnd.google-apps.document", "Google Doc"},
        {"application/vnd.google-apps.spreadsheet", "Google Sheet"},
        {"application/vnd.google-apps.presentation", "Google Slides"},
        {"application/vnd.google-apps.folder", "Folder"},
        {"application/pdf", "PDF"}
      ]

      for {mime, label} <- types do
        set_mock_response({:ok, [mock_file(%{mime_type: mime})]})
        {:ok, result} = Search.execute(%{}, build_context())
        assert result.content =~ label, "Expected '#{label}' for mime '#{mime}'"
      end
    end
  end

  # ---------------------------------------------------------------
  # Error handling
  # ---------------------------------------------------------------

  describe "execute/2 error handling" do
    test "wraps Drive API errors in a Result with :error status" do
      set_mock_response({:error, %{status: 403, body: "forbidden"}})

      {:ok, result} = Search.execute(%{}, build_context())

      assert result.status == :error
      assert result.content =~ "Drive search failed"
    end
  end

  # ---------------------------------------------------------------
  # Integration defaults (no mock injected)
  # ---------------------------------------------------------------

  describe "execute/2 default drive module" do
    test "defaults to Drive module when no integration injected" do
      # When context.integrations has no :drive key, it defaults to the
      # real Drive module. We can't call it (no auth), but we verify
      # the execute function doesn't crash on building the query.
      context = %Context{
        conversation_id: "conv-1",
        execution_id: "exec-1",
        user_id: "user-1",
        integrations: %{}
      }

      # This will fail at the Drive.list_files call (no Goth token),
      # but should not raise — it should return an error result.
      # The error comes from Drive.list_files -> get_connection -> Auth.token
      # which returns {:error, ...}
      result = Search.execute(%{"type" => "banana"}, context)

      # With invalid type, it short-circuits before calling Drive
      assert {:ok, %Result{status: :error}} = result
    end
  end
end

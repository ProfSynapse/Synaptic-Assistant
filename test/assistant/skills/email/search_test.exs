# test/assistant/skills/email/search_test.exs
#
# Tests for the email.search skill handler. Uses a MockGmail module
# injected via context.integrations[:gmail] to avoid real API calls.
# Tests query building, output formatting, limit parsing, and error handling.

defmodule Assistant.Skills.Email.SearchTest do
  use ExUnit.Case, async: true

  alias Assistant.Skills.Email.Search
  alias Assistant.Skills.Context

  # ---------------------------------------------------------------
  # Mock Gmail module
  # ---------------------------------------------------------------

  defmodule MockGmail do
    @moduledoc false

    def search_messages(_token, query, opts) do
      send(self(), {:gmail_search, query, opts})

      case Process.get(:mock_gmail_search_response) do
        nil -> {:ok, []}
        response -> response
      end
    end
  end

  # ---------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------

  defp build_context(overrides \\ %{}) do
    base = %Context{
      conversation_id: "conv-1",
      execution_id: "exec-1",
      user_id: "user-1",
      integrations: %{gmail: MockGmail},
      metadata: %{google_token: "test-access-token"}
    }

    Map.merge(base, overrides)
  end

  defp set_mock_response(response) do
    Process.put(:mock_gmail_search_response, response)
  end

  defp mock_message(attrs \\ %{}) do
    Map.merge(
      %{
        id: "msg_abc",
        subject: "Test Email",
        from: "sender@example.com",
        to: "recipient@example.com",
        date: "2026-02-18",
        body: "Hello world",
        snippet: "Hello world preview"
      },
      attrs
    )
  end

  # ---------------------------------------------------------------
  # Basic search
  # ---------------------------------------------------------------

  describe "execute/2 basic search" do
    test "returns 'No messages found' when results are empty" do
      set_mock_response({:ok, []})
      {:ok, result} = Search.execute(%{}, build_context())

      assert result.status == :ok
      assert result.content =~ "No messages found"
      assert result.metadata.count == 0
    end

    test "formats messages with count" do
      set_mock_response({:ok, [mock_message(), mock_message(%{id: "msg_def"})]})
      {:ok, result} = Search.execute(%{}, build_context())

      assert result.status == :ok
      assert result.content =~ "Found 2 message(s)"
      assert result.metadata.count == 2
    end

    test "includes message summary in output" do
      set_mock_response({:ok, [mock_message()]})
      {:ok, result} = Search.execute(%{}, build_context())

      assert result.content =~ "Test Email"
      assert result.content =~ "sender@example.com"
      assert result.content =~ "msg_abc"
    end
  end

  # ---------------------------------------------------------------
  # Query building
  # ---------------------------------------------------------------

  describe "execute/2 query building" do
    test "passes raw query text" do
      Search.execute(%{"query" => "important meeting"}, build_context())
      assert_received {:gmail_search, query, _opts}
      assert query =~ "important meeting"
    end

    test "adds from: prefix for --from flag" do
      Search.execute(%{"from" => "boss@example.com"}, build_context())
      assert_received {:gmail_search, query, _opts}
      assert query =~ "from:boss@example.com"
    end

    test "adds to: prefix for --to flag" do
      Search.execute(%{"to" => "me@example.com"}, build_context())
      assert_received {:gmail_search, query, _opts}
      assert query =~ "to:me@example.com"
    end

    test "adds after: prefix for --after flag" do
      Search.execute(%{"after" => "2026-02-01"}, build_context())
      assert_received {:gmail_search, query, _opts}
      assert query =~ "after:2026-02-01"
    end

    test "adds before: prefix for --before flag" do
      Search.execute(%{"before" => "2026-02-28"}, build_context())
      assert_received {:gmail_search, query, _opts}
      assert query =~ "before:2026-02-28"
    end

    test "adds is:unread when --unread flag is set" do
      Search.execute(%{"unread" => "true"}, build_context())
      assert_received {:gmail_search, query, _opts}
      assert query =~ "is:unread"
    end

    test "does not add is:unread when --unread is false" do
      Search.execute(%{"unread" => "false"}, build_context())
      assert_received {:gmail_search, query, _opts}
      refute query =~ "is:unread"
    end

    test "combines multiple flags into a single query" do
      flags = %{
        "query" => "project update",
        "from" => "boss@example.com",
        "after" => "2026-02-01",
        "unread" => "true"
      }

      Search.execute(flags, build_context())
      assert_received {:gmail_search, query, _opts}

      assert query =~ "project update"
      assert query =~ "from:boss@example.com"
      assert query =~ "after:2026-02-01"
      assert query =~ "is:unread"
    end

    test "ignores empty string flags" do
      Search.execute(%{"from" => "", "to" => ""}, build_context())
      assert_received {:gmail_search, query, _opts}
      refute query =~ "from:"
      refute query =~ "to:"
    end
  end

  # ---------------------------------------------------------------
  # Full mode
  # ---------------------------------------------------------------

  describe "execute/2 full mode" do
    test "shows body content when --full is set" do
      set_mock_response({:ok, [mock_message(%{body: "Full body content here"})]})
      {:ok, result} = Search.execute(%{"full" => "true"}, build_context())

      assert result.content =~ "Full body content here"
    end

    test "does not show full body in summary mode" do
      set_mock_response({:ok, [mock_message(%{body: "Full body content here"})]})
      {:ok, result} = Search.execute(%{}, build_context())

      # Summary mode shows snippet, not full body
      refute result.content =~ "Full body content here"
    end

    test "--full=false uses summary mode" do
      set_mock_response({:ok, [mock_message()]})
      {:ok, result} = Search.execute(%{"full" => "false"}, build_context())

      assert result.content =~ "Found 1 message(s)"
    end
  end

  # ---------------------------------------------------------------
  # Limit handling
  # ---------------------------------------------------------------

  describe "execute/2 limit handling" do
    test "uses default limit of 10" do
      Search.execute(%{}, build_context())
      assert_received {:gmail_search, _query, opts}
      assert Keyword.get(opts, :limit) == 10
    end

    test "passes custom limit from flags" do
      Search.execute(%{"limit" => "5"}, build_context())
      assert_received {:gmail_search, _query, opts}
      assert Keyword.get(opts, :limit) == 5
    end

    test "clamps limit to max 50" do
      Search.execute(%{"limit" => "999"}, build_context())
      assert_received {:gmail_search, _query, opts}
      assert Keyword.get(opts, :limit) == 50
    end

    test "clamps limit to min 1" do
      Search.execute(%{"limit" => "0"}, build_context())
      assert_received {:gmail_search, _query, opts}
      assert Keyword.get(opts, :limit) == 1
    end

    test "uses default for non-numeric limit" do
      Search.execute(%{"limit" => "abc"}, build_context())
      assert_received {:gmail_search, _query, opts}
      assert Keyword.get(opts, :limit) == 10
    end

    test "handles integer limit value" do
      Search.execute(%{"limit" => 7}, build_context())
      assert_received {:gmail_search, _query, opts}
      assert Keyword.get(opts, :limit) == 7
    end
  end

  # ---------------------------------------------------------------
  # Error handling
  # ---------------------------------------------------------------

  describe "execute/2 error handling" do
    test "wraps Gmail API errors in error result" do
      set_mock_response({:error, %{status: 403, body: "forbidden"}})
      {:ok, result} = Search.execute(%{}, build_context())

      assert result.status == :error
      assert result.content =~ "Gmail search failed"
    end
  end

  # ---------------------------------------------------------------
  # No Gmail integration
  # ---------------------------------------------------------------

  describe "execute/2 without Gmail integration" do
    test "returns error when gmail integration is nil" do
      context = build_context(%{integrations: %{}})
      {:ok, result} = Search.execute(%{}, context)

      assert result.status == :error
      assert result.content =~ "Gmail integration not configured"
    end
  end
end

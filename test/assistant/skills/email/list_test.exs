# test/assistant/skills/email/list_test.exs
#
# Tests for the email.list skill handler. Uses a MockGmail module
# injected via context.integrations[:gmail] to avoid real API calls.
# Tests label filtering, unread mode, full mode, and limit handling.

defmodule Assistant.Skills.Email.ListTest do
  use ExUnit.Case, async: true

  alias Assistant.Skills.Email.List
  alias Assistant.Skills.Context

  # ---------------------------------------------------------------
  # Mock Gmail module
  # ---------------------------------------------------------------

  defmodule MockGmail do
    @moduledoc false

    def list_messages(user_id, query, opts) do
      send(self(), {:gmail_list, user_id, query, opts})

      case Process.get(:mock_gmail_list_response) do
        nil -> {:ok, []}
        response -> response
      end
    end

    def get_message(id, _user_id \\ "me", _opts \\ []) do
      send(self(), {:gmail_get, id})

      case Process.get(:mock_gmail_get_response) do
        nil ->
          {:ok,
           %{
             id: id,
             subject: "Message #{id}",
             from: "sender@example.com",
             to: "recipient@example.com",
             date: "2026-02-18",
             body: "Body for #{id}"
           }}

        response ->
          response
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
      integrations: %{gmail: MockGmail}
    }

    Map.merge(base, overrides)
  end

  defp set_list_response(response) do
    Process.put(:mock_gmail_list_response, response)
  end

  # ---------------------------------------------------------------
  # Basic listing
  # ---------------------------------------------------------------

  describe "execute/2 basic listing" do
    test "returns 'No messages found' when inbox is empty" do
      set_list_response({:ok, []})
      {:ok, result} = List.execute(%{}, build_context())

      assert result.status == :ok
      assert result.content =~ "No messages found"
      assert result.metadata.count == 0
    end

    test "lists messages with count" do
      set_list_response({:ok, [%{id: "msg_1"}, %{id: "msg_2"}]})
      {:ok, result} = List.execute(%{}, build_context())

      assert result.status == :ok
      assert result.content =~ "Showing 2 message(s)"
      assert result.metadata.count == 2
    end

    test "resolves message IDs to full messages" do
      set_list_response({:ok, [%{id: "msg_1"}]})
      List.execute(%{}, build_context())

      assert_received {:gmail_list, "me", _query, _opts}
      assert_received {:gmail_get, "msg_1"}
    end
  end

  # ---------------------------------------------------------------
  # Label and query building
  # ---------------------------------------------------------------

  describe "execute/2 query building" do
    test "defaults to INBOX label" do
      List.execute(%{}, build_context())
      assert_received {:gmail_list, "me", query, _opts}
      assert query =~ "label:INBOX"
    end

    test "uses custom label from --label flag" do
      List.execute(%{"label" => "SENT"}, build_context())
      assert_received {:gmail_list, "me", query, _opts}
      assert query =~ "label:SENT"
    end

    test "adds is:unread when --unread flag is set" do
      List.execute(%{"unread" => "true"}, build_context())
      assert_received {:gmail_list, "me", query, _opts}
      assert query =~ "is:unread"
    end

    test "does not add is:unread when flag is false" do
      List.execute(%{"unread" => "false"}, build_context())
      assert_received {:gmail_list, "me", query, _opts}
      refute query =~ "is:unread"
    end
  end

  # ---------------------------------------------------------------
  # Limit handling
  # ---------------------------------------------------------------

  describe "execute/2 limit handling" do
    test "uses default limit of 10" do
      List.execute(%{}, build_context())
      assert_received {:gmail_list, "me", _query, opts}
      assert Keyword.get(opts, :max_results) == 10
    end

    test "passes custom limit" do
      List.execute(%{"limit" => "5"}, build_context())
      assert_received {:gmail_list, "me", _query, opts}
      assert Keyword.get(opts, :max_results) == 5
    end

    test "clamps limit to max 50" do
      List.execute(%{"limit" => "200"}, build_context())
      assert_received {:gmail_list, "me", _query, opts}
      assert Keyword.get(opts, :max_results) == 50
    end

    test "clamps limit to min 1" do
      List.execute(%{"limit" => "0"}, build_context())
      assert_received {:gmail_list, "me", _query, opts}
      assert Keyword.get(opts, :max_results) == 1
    end
  end

  # ---------------------------------------------------------------
  # Full mode
  # ---------------------------------------------------------------

  describe "execute/2 full mode" do
    test "includes body in full mode" do
      set_list_response({:ok, [%{id: "msg_1"}]})
      {:ok, result} = List.execute(%{"full" => "true"}, build_context())

      assert result.content =~ "Body for msg_1"
    end
  end

  # ---------------------------------------------------------------
  # Error handling
  # ---------------------------------------------------------------

  describe "execute/2 error handling" do
    test "wraps list API errors" do
      set_list_response({:error, %{status: 403, body: "forbidden"}})
      {:ok, result} = List.execute(%{}, build_context())

      assert result.status == :error
      assert result.content =~ "Failed to list messages"
    end
  end

  # ---------------------------------------------------------------
  # No Gmail integration
  # ---------------------------------------------------------------

  describe "execute/2 without Gmail integration" do
    test "returns error when gmail integration is nil" do
      context = build_context(%{integrations: %{}})
      {:ok, result} = List.execute(%{}, context)

      assert result.status == :error
      assert result.content =~ "Gmail integration not configured"
    end
  end
end

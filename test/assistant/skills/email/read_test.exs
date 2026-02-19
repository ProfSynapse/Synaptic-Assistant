# test/assistant/skills/email/read_test.exs
#
# Tests for the email.read skill handler. Uses a MockGmail module
# injected via context.integrations[:gmail] to avoid real API calls.
# Tests single and batch ID reading, error handling, and formatting.

defmodule Assistant.Skills.Email.ReadTest do
  use ExUnit.Case, async: true

  alias Assistant.Skills.Email.Read
  alias Assistant.Skills.Context

  # ---------------------------------------------------------------
  # Mock Gmail module
  # ---------------------------------------------------------------

  defmodule MockGmail do
    @moduledoc false

    def get_message(id, _user_id \\ "me", _opts \\ []) do
      send(self(), {:gmail_get, id})

      case Process.get({:mock_gmail_get_response, id}) do
        nil ->
          case Process.get(:mock_gmail_get_response) do
            nil ->
              {:ok,
               %{
                 id: id,
                 subject: "Test Subject",
                 from: "sender@example.com",
                 to: "recipient@example.com",
                 date: "2026-02-18",
                 body: "Hello world"
               }}

            response ->
              response
          end

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

  defp set_mock_response(response) do
    Process.put(:mock_gmail_get_response, response)
  end

  defp set_mock_response_for(id, response) do
    Process.put({:mock_gmail_get_response, id}, response)
  end

  # ---------------------------------------------------------------
  # Single message reading
  # ---------------------------------------------------------------

  describe "execute/2 single message" do
    test "reads a single message by ID" do
      {:ok, result} = Read.execute(%{"id" => "msg_123"}, build_context())

      assert result.status == :ok
      assert result.content =~ "Test Subject"
      assert result.content =~ "sender@example.com"
      assert result.content =~ "Hello world"
      assert result.metadata.message_ids == ["msg_123"]
    end

    test "calls Gmail client with the message ID" do
      Read.execute(%{"id" => "msg_123"}, build_context())
      assert_received {:gmail_get, "msg_123"}
    end
  end

  # ---------------------------------------------------------------
  # Batch reading (comma-separated IDs)
  # ---------------------------------------------------------------

  describe "execute/2 batch reading" do
    test "reads multiple comma-separated IDs" do
      {:ok, result} = Read.execute(%{"id" => "msg_1, msg_2, msg_3"}, build_context())

      assert result.status == :ok
      assert result.metadata.message_ids == ["msg_1", "msg_2", "msg_3"]

      assert_received {:gmail_get, "msg_1"}
      assert_received {:gmail_get, "msg_2"}
      assert_received {:gmail_get, "msg_3"}
    end

    test "separates messages with dividers" do
      {:ok, result} = Read.execute(%{"id" => "msg_1, msg_2"}, build_context())

      assert result.content =~ "---"
    end

    test "handles mixed success and failure" do
      set_mock_response_for("msg_ok", {:ok, %{
        id: "msg_ok",
        subject: "Good Message",
        from: "a@b.com",
        to: "c@d.com",
        date: "2026-02-18",
        body: "Content"
      }})
      set_mock_response_for("msg_fail", {:error, :not_found})

      {:ok, result} = Read.execute(%{"id" => "msg_ok, msg_fail"}, build_context())

      assert result.content =~ "Good Message"
      assert result.content =~ "Message not found: msg_fail"
    end
  end

  # ---------------------------------------------------------------
  # Missing ID parameter
  # ---------------------------------------------------------------

  describe "execute/2 missing ID" do
    test "returns error when --id is missing" do
      {:ok, result} = Read.execute(%{}, build_context())

      assert result.status == :error
      assert result.content =~ "--id"
    end

    test "returns error when --id is empty" do
      {:ok, result} = Read.execute(%{"id" => ""}, build_context())

      assert result.status == :error
      assert result.content =~ "--id"
    end
  end

  # ---------------------------------------------------------------
  # Error handling
  # ---------------------------------------------------------------

  describe "execute/2 error handling" do
    test "formats :not_found error" do
      set_mock_response({:error, :not_found})
      {:ok, result} = Read.execute(%{"id" => "missing_msg"}, build_context())

      assert result.content =~ "Message not found"
    end

    test "formats generic error" do
      set_mock_response({:error, %{status: 500, body: "server error"}})
      {:ok, result} = Read.execute(%{"id" => "err_msg"}, build_context())

      assert result.content =~ "Failed to read message"
    end
  end

  # ---------------------------------------------------------------
  # No Gmail integration
  # ---------------------------------------------------------------

  describe "execute/2 without Gmail integration" do
    test "returns error when gmail integration is nil" do
      context = build_context(%{integrations: %{}})
      {:ok, result} = Read.execute(%{"id" => "msg_123"}, context)

      assert result.status == :error
      assert result.content =~ "Gmail integration not configured"
    end
  end
end

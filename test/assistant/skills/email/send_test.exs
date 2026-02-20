# test/assistant/skills/email/send_test.exs
#
# Tests for the email.send skill handler. Uses a MockGmail module
# injected via context.integrations[:gmail] to avoid real API calls.
# Tests parameter validation, header injection prevention, and result formatting.

defmodule Assistant.Skills.Email.SendTest do
  use ExUnit.Case, async: true

  alias Assistant.Skills.Email.Send
  alias Assistant.Skills.Context

  # ---------------------------------------------------------------
  # Mock Gmail module
  # ---------------------------------------------------------------

  defmodule MockGmail do
    @moduledoc false

    def send_message(_token, to, subject, body, opts) do
      send(self(), {:gmail_send, to, subject, body, opts})

      case Process.get(:mock_gmail_response) do
        nil -> {:ok, %{id: "msg_123", thread_id: "thread_456"}}
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
    Process.put(:mock_gmail_response, response)
  end

  defp valid_flags do
    %{
      "to" => "recipient@example.com",
      "subject" => "Test Subject",
      "body" => "Hello, this is a test."
    }
  end

  # ---------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------

  describe "execute/2 happy path" do
    test "sends email and returns success result" do
      {:ok, result} = Send.execute(valid_flags(), build_context())

      assert result.status == :ok
      assert result.content =~ "Email sent successfully"
      assert result.content =~ "recipient@example.com"
      assert result.content =~ "Test Subject"
      assert result.content =~ "msg_123"
      assert result.side_effects == [:email_sent]
      assert result.metadata.message_id == "msg_123"
      assert result.metadata.to == "recipient@example.com"
    end

    test "passes correct arguments to Gmail client" do
      Send.execute(valid_flags(), build_context())

      assert_received {:gmail_send, "recipient@example.com", "Test Subject",
                       "Hello, this is a test.", []}
    end

    test "includes cc option when provided" do
      flags = Map.put(valid_flags(), "cc", "cc@example.com")
      Send.execute(flags, build_context())

      assert_received {:gmail_send, _, _, _, [cc: "cc@example.com"]}
    end

    test "omits cc option when not provided" do
      Send.execute(valid_flags(), build_context())
      assert_received {:gmail_send, _, _, _, []}
    end
  end

  # ---------------------------------------------------------------
  # Missing required parameters
  # ---------------------------------------------------------------

  describe "execute/2 missing parameters" do
    test "returns error when --to is missing" do
      flags = Map.delete(valid_flags(), "to")
      {:ok, result} = Send.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "--to"
    end

    test "returns error when --to is empty" do
      flags = Map.put(valid_flags(), "to", "")
      {:ok, result} = Send.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "--to"
    end

    test "returns error when --subject is missing" do
      flags = Map.delete(valid_flags(), "subject")
      {:ok, result} = Send.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "--subject"
    end

    test "returns error when --subject is empty" do
      flags = Map.put(valid_flags(), "subject", "")
      {:ok, result} = Send.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "--subject"
    end

    test "returns error when --body is missing" do
      flags = Map.delete(valid_flags(), "body")
      {:ok, result} = Send.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "--body"
    end

    test "returns error when --body is empty" do
      flags = Map.put(valid_flags(), "body", "")
      {:ok, result} = Send.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "--body"
    end
  end

  # ---------------------------------------------------------------
  # Header injection prevention
  # ---------------------------------------------------------------

  describe "execute/2 header injection prevention" do
    test "rejects newline in --to" do
      flags = Map.put(valid_flags(), "to", "evil@example.com\r\nBcc: victim@example.com")
      {:ok, result} = Send.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "--to"
      assert result.content =~ "newline"
    end

    test "rejects bare \\n in --to" do
      flags = Map.put(valid_flags(), "to", "evil@example.com\nBcc: victim@example.com")
      {:ok, result} = Send.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "--to"
    end

    test "rejects newline in --subject" do
      flags = Map.put(valid_flags(), "subject", "Hello\r\nBcc: victim@example.com")
      {:ok, result} = Send.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "--subject"
      assert result.content =~ "newline"
    end

    test "rejects newline in --cc" do
      flags = Map.merge(valid_flags(), %{"cc" => "cc@example.com\r\nBcc: victim@example.com"})
      {:ok, result} = Send.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "--cc"
      assert result.content =~ "newline"
    end

    test "allows cc without newlines" do
      flags = Map.put(valid_flags(), "cc", "valid@example.com")
      {:ok, result} = Send.execute(flags, build_context())

      assert result.status == :ok
    end
  end

  # ---------------------------------------------------------------
  # Gmail API errors
  # ---------------------------------------------------------------

  describe "execute/2 error handling" do
    test "handles :header_injection error from Gmail client" do
      set_mock_response({:error, :header_injection})
      {:ok, result} = Send.execute(valid_flags(), build_context())

      assert result.status == :error
      assert result.content =~ "header injection"
    end

    test "handles generic Gmail API error" do
      set_mock_response({:error, %{status: 403, body: "forbidden"}})
      {:ok, result} = Send.execute(valid_flags(), build_context())

      assert result.status == :error
      assert result.content =~ "Failed to send email"
    end
  end

  # ---------------------------------------------------------------
  # No Gmail integration
  # ---------------------------------------------------------------

  describe "execute/2 without Gmail integration" do
    test "returns error when gmail integration is nil" do
      context = build_context(%{integrations: %{}})
      {:ok, result} = Send.execute(valid_flags(), context)

      assert result.status == :error
      assert result.content =~ "Gmail integration not configured"
    end
  end
end

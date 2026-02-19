# test/assistant/skills/email/draft_test.exs
#
# Tests for the email.draft skill handler. Uses a MockGmail module
# injected via context.integrations[:gmail] to avoid real API calls.
# Tests parameter validation, header injection prevention, and result formatting.

defmodule Assistant.Skills.Email.DraftTest do
  use ExUnit.Case, async: true

  alias Assistant.Skills.Email.Draft
  alias Assistant.Skills.Context

  # ---------------------------------------------------------------
  # Mock Gmail module
  # ---------------------------------------------------------------

  defmodule MockGmail do
    @moduledoc false

    def create_draft(to, subject, body, opts) do
      send(self(), {:gmail_draft, to, subject, body, opts})

      case Process.get(:mock_gmail_draft_response) do
        nil -> {:ok, %{id: "draft_123"}}
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
      integrations: %{gmail: MockGmail}
    }

    Map.merge(base, overrides)
  end

  defp set_mock_response(response) do
    Process.put(:mock_gmail_draft_response, response)
  end

  defp valid_flags do
    %{
      "to" => "recipient@example.com",
      "subject" => "Draft Subject",
      "body" => "Draft body text."
    }
  end

  # ---------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------

  describe "execute/2 happy path" do
    test "creates draft and returns success result" do
      {:ok, result} = Draft.execute(valid_flags(), build_context())

      assert result.status == :ok
      assert result.content =~ "Draft created successfully"
      assert result.content =~ "recipient@example.com"
      assert result.content =~ "Draft Subject"
      assert result.content =~ "draft_123"
      assert result.metadata.draft_id == "draft_123"
      assert result.metadata.to == "recipient@example.com"
    end

    test "passes correct arguments to Gmail client" do
      Draft.execute(valid_flags(), build_context())

      assert_received {:gmail_draft, "recipient@example.com", "Draft Subject", "Draft body text.",
                       []}
    end

    test "includes cc option when provided" do
      flags = Map.put(valid_flags(), "cc", "cc@example.com")
      Draft.execute(flags, build_context())

      assert_received {:gmail_draft, _, _, _, [cc: "cc@example.com"]}
    end
  end

  # ---------------------------------------------------------------
  # Missing required parameters
  # ---------------------------------------------------------------

  describe "execute/2 missing parameters" do
    test "returns error when --to is missing" do
      flags = Map.delete(valid_flags(), "to")
      {:ok, result} = Draft.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "--to"
    end

    test "returns error when --subject is missing" do
      flags = Map.delete(valid_flags(), "subject")
      {:ok, result} = Draft.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "--subject"
    end

    test "returns error when --body is missing" do
      flags = Map.delete(valid_flags(), "body")
      {:ok, result} = Draft.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "--body"
    end

    test "returns error when --to is empty string" do
      flags = Map.put(valid_flags(), "to", "")
      {:ok, result} = Draft.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "--to"
    end
  end

  # ---------------------------------------------------------------
  # Header injection prevention
  # ---------------------------------------------------------------

  describe "execute/2 header injection prevention" do
    test "rejects newline in --to" do
      flags = Map.put(valid_flags(), "to", "evil@example.com\r\nBcc: victim@example.com")
      {:ok, result} = Draft.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "--to"
    end

    test "rejects newline in --subject" do
      flags = Map.put(valid_flags(), "subject", "Hello\nBcc: victim@example.com")
      {:ok, result} = Draft.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "--subject"
    end

    test "rejects newline in --cc" do
      flags = Map.merge(valid_flags(), %{"cc" => "cc@example.com\r\nBcc: victim@example.com"})
      {:ok, result} = Draft.execute(flags, build_context())

      assert result.status == :error
      assert result.content =~ "--cc"
    end
  end

  # ---------------------------------------------------------------
  # Gmail API errors
  # ---------------------------------------------------------------

  describe "execute/2 error handling" do
    test "handles :header_injection error from Gmail client" do
      set_mock_response({:error, :header_injection})
      {:ok, result} = Draft.execute(valid_flags(), build_context())

      assert result.status == :error
      assert result.content =~ "header injection"
    end

    test "handles generic Gmail API error" do
      set_mock_response({:error, %{status: 500, body: "internal error"}})
      {:ok, result} = Draft.execute(valid_flags(), build_context())

      assert result.status == :error
      assert result.content =~ "Failed to create draft"
    end
  end

  # ---------------------------------------------------------------
  # No Gmail integration
  # ---------------------------------------------------------------

  describe "execute/2 without Gmail integration" do
    test "returns error when gmail integration is nil" do
      context = build_context(%{integrations: %{}})
      {:ok, result} = Draft.execute(valid_flags(), context)

      assert result.status == :error
      assert result.content =~ "Gmail integration not configured"
    end
  end
end

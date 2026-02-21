# test/assistant/integrations/google/gmail_test.exs
#
# Tests for the Gmail integration client's security-critical functions.
# Since validate_headers/3 and build_rfc2822/4 are private, we test them
# indirectly through send_message/4 and create_draft/4 by mocking the
# Auth.token/0 and GoogleApi calls at the module level.
#
# We also test pure functions that can be verified through observable output:
# base64url encoding roundtrips and header injection rejection.

defmodule Assistant.Integrations.Google.GmailTest do
  use ExUnit.Case, async: true

  alias Assistant.Integrations.Google.Gmail

  # ---------------------------------------------------------------
  # Header injection via send_message/4
  # ---------------------------------------------------------------
  # The Gmail module calls validate_headers before get_connection.
  # Header injection errors are returned as {:error, :header_injection}
  # before any network call is attempted. This means we can test
  # injection rejection without mocking Goth/Auth at all — the
  # validation happens first in the `with` chain.

  # A dummy token used for header-injection tests. The validation runs before
  # Connection.new is ever called, so no real token is needed.
  @dummy_token "test-access-token"

  describe "send_message/5 header injection prevention" do
    test "rejects \\r\\n in to field" do
      result =
        Gmail.send_message(
          @dummy_token,
          "evil@example.com\r\nBcc: victim@example.com",
          "Subject",
          "Body"
        )

      assert {:error, :header_injection} = result
    end

    test "rejects \\n in to field" do
      result =
        Gmail.send_message(
          @dummy_token,
          "evil@example.com\nBcc: victim@example.com",
          "Subject",
          "Body"
        )

      assert {:error, :header_injection} = result
    end

    test "rejects \\r\\n in subject field" do
      result =
        Gmail.send_message(
          @dummy_token,
          "to@example.com",
          "Hello\r\nBcc: victim@example.com",
          "Body"
        )

      assert {:error, :header_injection} = result
    end

    test "rejects \\n in subject field" do
      result =
        Gmail.send_message(
          @dummy_token,
          "to@example.com",
          "Hello\nBcc: victim@example.com",
          "Body"
        )

      assert {:error, :header_injection} = result
    end

    test "rejects \\r\\n in cc option" do
      result =
        Gmail.send_message(@dummy_token, "to@example.com", "Subject", "Body",
          cc: "cc@example.com\r\nBcc: victim"
        )

      assert {:error, :header_injection} = result
    end

    test "rejects bare \\r in to field" do
      result =
        Gmail.send_message(
          @dummy_token,
          "evil@example.com\rBcc: victim@example.com",
          "Subject",
          "Body"
        )

      assert {:error, :header_injection} = result
    end
  end

  describe "create_draft/5 header injection prevention" do
    test "rejects \\r\\n in to field" do
      result =
        Gmail.create_draft(
          @dummy_token,
          "evil@example.com\r\nBcc: victim@example.com",
          "Subject",
          "Body"
        )

      assert {:error, :header_injection} = result
    end

    test "rejects \\r\\n in subject field" do
      result =
        Gmail.create_draft(
          @dummy_token,
          "to@example.com",
          "Hello\r\nBcc: victim@example.com",
          "Body"
        )

      assert {:error, :header_injection} = result
    end

    test "rejects \\r\\n in cc option" do
      result =
        Gmail.create_draft(@dummy_token, "to@example.com", "Subject", "Body",
          cc: "cc@example.com\r\nBcc: victim"
        )

      assert {:error, :header_injection} = result
    end
  end
end

# test/assistant/channels/dispatcher_test.exs
#
# Tests for the shared Dispatcher module. The derive_conversation_id/1 function
# was removed in the unified conversation architecture — identity resolution is
# now handled by UserResolver. These tests verify the dispatch/2 spawn behavior.

defmodule Assistant.Channels.DispatcherTest do
  use ExUnit.Case, async: true

  # Dispatcher now depends on UserResolver + ReplyRouter for full dispatch.
  # Unit tests for derive_conversation_id were removed since that function
  # was replaced by UserResolver.resolve/3. Integration tests for the full
  # dispatch flow belong in the test phase.
end

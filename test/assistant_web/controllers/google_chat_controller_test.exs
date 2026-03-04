defmodule AssistantWeb.GoogleChatControllerTest do
  use AssistantWeb.ConnCase, async: false

  alias AssistantWeb.GoogleChatController

  @timeout_message "Sorry, processing took too long. Please try again."

  setup do
    prev_dispatcher = Application.get_env(:assistant, :google_chat_dispatcher_module)
    prev_timeout = Application.get_env(:assistant, :google_chat_sync_timeout_ms)
    prev_mode = Application.get_env(:assistant, :google_chat_dispatcher_stub_mode)

    Application.put_env(
      :assistant,
      :google_chat_dispatcher_module,
      Assistant.TestSupport.GoogleChatDispatcherStub
    )

    on_exit(fn ->
      restore_env(:google_chat_dispatcher_module, prev_dispatcher)
      restore_env(:google_chat_sync_timeout_ms, prev_timeout)
      restore_env(:google_chat_dispatcher_stub_mode, prev_mode)
    end)

    :ok
  end

  describe "event/2 sync dispatch guard rails" do
    test "returns timeout message when sync dispatch task exceeds timeout", %{conn: conn} do
      Application.put_env(:assistant, :google_chat_dispatcher_stub_mode, :sleep)
      Application.put_env(:assistant, :google_chat_sync_timeout_ms, 10)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> GoogleChatController.event(v1_message_event())

      assert json_response(conn, 200) == %{"text" => @timeout_message}
    end

    test "returns timeout message when sync dispatch task exits", %{conn: conn} do
      Application.put_env(:assistant, :google_chat_dispatcher_stub_mode, :exit)
      Application.put_env(:assistant, :google_chat_sync_timeout_ms, 100)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> GoogleChatController.event(v1_message_event())

      assert json_response(conn, 200) == %{"text" => @timeout_message}
    end

    test "returns v2 hostAppDataAction envelope when sync dispatch times out", %{conn: conn} do
      Application.put_env(:assistant, :google_chat_dispatcher_stub_mode, :sleep)
      Application.put_env(:assistant, :google_chat_sync_timeout_ms, 10)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> GoogleChatController.event(v2_message_event())

      assert json_response(conn, 200) ==
               %{
                 "hostAppDataAction" => %{
                   "chatDataAction" => %{
                     "createMessageAction" => %{
                       "message" => %{"text" => @timeout_message}
                     }
                   }
                 }
               }
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:assistant, key)
  defp restore_env(key, value), do: Application.put_env(:assistant, key, value)

  defp v1_message_event do
    %{
      "type" => "MESSAGE",
      "eventTime" => "2026-03-04T10:00:00Z",
      "space" => %{"name" => "spaces/AAAA", "type" => "DM"},
      "user" => %{"name" => "users/test_user_1", "displayName" => "Test User"},
      "message" => %{
        "name" => "spaces/AAAA/messages/msg1",
        "text" => "hello"
      }
    }
  end

  defp v2_message_event do
    %{
      "chat" => %{
        "eventTime" => "2026-03-04T10:00:00Z",
        "user" => %{"name" => "users/test_user_1", "displayName" => "Test User"},
        "messagePayload" => %{
          "space" => %{"name" => "spaces/AAAA", "type" => "DM"},
          "message" => %{
            "name" => "spaces/AAAA/messages/msg2",
            "text" => "hello from v2",
            "thread" => %{"name" => "spaces/AAAA/threads/thread1"}
          }
        }
      },
      "commonEventObject" => %{}
    }
  end
end

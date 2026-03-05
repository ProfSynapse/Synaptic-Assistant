defmodule AssistantWeb.GoogleChatControllerTest do
  use AssistantWeb.ConnCase, async: false

  alias AssistantWeb.GoogleChatController

  @thinking_message "Thinking..."

  describe "event/2 async dispatch" do
    test "returns v1 thinking response immediately for MESSAGE event", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> GoogleChatController.event(v1_message_event())

      assert json_response(conn, 200) == %{"text" => @thinking_message}
    end

    test "returns v2 hostAppDataAction envelope for MESSAGE event", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> GoogleChatController.event(v2_message_event())

      assert json_response(conn, 200) ==
               %{
                 "hostAppDataAction" => %{
                   "chatDataAction" => %{
                     "createMessageAction" => %{
                       "message" => %{"text" => @thinking_message}
                     }
                   }
                 }
               }
    end
  end

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

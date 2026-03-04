defmodule Assistant.TestSupport.GoogleChatDispatcherStub do
  @moduledoc false

  def dispatch_sync(_message) do
    case Application.get_env(:assistant, :google_chat_dispatcher_stub_mode, :ok) do
      :ok ->
        {:ok, "stub response"}

      :error ->
        {:error, "stub error"}

      :sleep ->
        Process.sleep(100)
        {:ok, "late response"}

      :exit ->
        exit(:stub_exit)
    end
  end
end

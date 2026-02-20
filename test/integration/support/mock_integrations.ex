# test/integration/support/mock_integrations.ex — Mock integration modules for integration tests.
#
# Provides mock implementations of Google Gmail, Calendar, Drive, and OpenRouter
# integration modules. Each mock returns realistic fixture data and records calls
# via a shared ETS table for cross-process assertion. Skills execute inside
# Task.Supervisor child processes, so process-dictionary recording would be lost.
#
# Call recording: MockCallRecorder manages the ETS table.
# Use clear_mock_calls/0 and mock_was_called?/1 from integration_helpers.ex.
#
# Related files:
#   - lib/assistant/integrations/google/gmail.ex (real Gmail client)
#   - lib/assistant/integrations/google/calendar.ex (real Calendar client)
#   - lib/assistant/integrations/google/drive.ex (real Drive client)
#   - lib/assistant/integrations/openrouter.ex (real OpenRouter client)
#   - test/integration/support/integration_helpers.ex (test helper that injects these)

defmodule Assistant.Integration.MockCallRecorder do
  @moduledoc false

  # WARNING: This module uses a single named ETS table shared across all tests.
  # Integration test modules MUST use `async: false` to prevent concurrent test
  # processes from interleaving mock call records. If you add a new integration
  # test module, always set `use ExUnit.Case, async: false` (or DataCase, async: false).

  @table :integration_mock_calls

  @doc """
  Ensures the ETS table exists. Must be called from a long-lived process
  (e.g., the test process) so the table survives short-lived task processes.

  Skill handlers execute inside Task.Supervisor child processes. If the
  table were created by a child process, it would be destroyed when that
  process exits — losing all recorded calls before the test can assert.
  """
  def ensure_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :bag])
    end

    :ok
  end

  def record(domain, function) do
    # Table must already exist (created by test process via ensure_table/0).
    # Do NOT call ensure_table here — that would make a child process the owner.
    :ets.insert(@table, {domain, function, System.monotonic_time()})
  end

  def calls(domain) do
    if :ets.info(@table) == :undefined do
      []
    else
      @table
      |> :ets.match({domain, :"$1", :_})
      |> List.flatten()
    end
  end

  def called?(domain) do
    calls(domain) != []
  end

  @doc """
  Clears all recorded calls and ensures the table exists.
  Should be called from setup/0 in the test process.
  """
  def clear do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end
end

defmodule Assistant.Integration.MockGmail do
  @moduledoc false

  alias Assistant.Integration.MockCallRecorder

  def list_messages(_user_id \\ "me", _query, _opts \\ []) do
    MockCallRecorder.record(:gmail, :list_messages)

    {:ok,
     [
       %{id: "msg_int_001", thread_id: "thread_int_001"},
       %{id: "msg_int_002", thread_id: "thread_int_002"}
     ]}
  end

  def get_message(_message_id, _user_id \\ "me", _opts \\ []) do
    MockCallRecorder.record(:gmail, :get_message)

    {:ok,
     %{
       id: "msg_int_001",
       thread_id: "thread_int_001",
       subject: "Weekly Report Q1 2026",
       from: "alice@example.com",
       to: "team@example.com",
       date: "Thu, 20 Feb 2026 10:30:00 -0500",
       body: "Hi team,\n\nHere is the weekly report for Q1 2026.\n\nBest,\nAlice",
       snippet: "Hi team, Here is the weekly report..."
     }}
  end

  def send_message(_to, _subject, _body, _opts \\ []) do
    MockCallRecorder.record(:gmail, :send_message)
    {:ok, %{id: "msg_sent_001", thread_id: "thread_sent_001"}}
  end

  def create_draft(_to, _subject, _body, _opts \\ []) do
    MockCallRecorder.record(:gmail, :create_draft)
    {:ok, %{id: "draft_001"}}
  end

  def search_messages(_query, _opts \\ []) do
    MockCallRecorder.record(:gmail, :search_messages)

    {:ok,
     [
       %{
         id: "msg_int_001",
         thread_id: "thread_int_001",
         subject: "Weekly Report Q1 2026",
         from: "alice@example.com",
         to: "team@example.com",
         date: "Thu, 20 Feb 2026 10:30:00 -0500",
         body: "Hi team,\n\nHere is the weekly report.\n\nBest,\nAlice",
         snippet: "Hi team, Here is the weekly report..."
       }
     ]}
  end
end

defmodule Assistant.Integration.MockCalendar do
  @moduledoc false

  alias Assistant.Integration.MockCallRecorder

  def list_events(_calendar_id \\ "primary", _opts \\ []) do
    MockCallRecorder.record(:calendar, :list_events)

    {:ok,
     [
       %{
         id: "evt_001",
         summary: "Team Standup",
         description: "Daily standup meeting",
         location: "Conference Room A",
         start: "2026-02-20T09:00:00Z",
         end: "2026-02-20T09:30:00Z",
         attendees: ["alice@example.com", "bob@example.com"],
         html_link: "https://calendar.google.com/event?eid=evt_001",
         status: "confirmed"
       },
       %{
         id: "evt_002",
         summary: "Sprint Planning",
         description: "Bi-weekly sprint planning",
         location: nil,
         start: "2026-02-20T14:00:00Z",
         end: "2026-02-20T15:00:00Z",
         attendees: ["team@example.com"],
         html_link: "https://calendar.google.com/event?eid=evt_002",
         status: "confirmed"
       }
     ]}
  end

  def get_event(_event_id, _calendar_id \\ "primary") do
    MockCallRecorder.record(:calendar, :get_event)

    {:ok,
     %{
       id: "evt_001",
       summary: "Team Standup",
       description: "Daily standup meeting",
       location: "Conference Room A",
       start: "2026-02-20T09:00:00Z",
       end: "2026-02-20T09:30:00Z",
       attendees: ["alice@example.com", "bob@example.com"],
       html_link: "https://calendar.google.com/event?eid=evt_001",
       status: "confirmed"
     }}
  end

  def create_event(_event_params, _calendar_id \\ "primary") do
    MockCallRecorder.record(:calendar, :create_event)

    {:ok,
     %{
       id: "evt_new_001",
       summary: "New Meeting",
       description: nil,
       location: nil,
       start: "2026-02-21T10:00:00Z",
       end: "2026-02-21T11:00:00Z",
       attendees: [],
       html_link: "https://calendar.google.com/event?eid=evt_new_001",
       status: "confirmed"
     }}
  end

  def update_event(_event_id, _event_params, _calendar_id \\ "primary") do
    MockCallRecorder.record(:calendar, :update_event)

    {:ok,
     %{
       id: "evt_001",
       summary: "Updated Standup",
       description: "Updated description",
       location: "Conference Room B",
       start: "2026-02-20T09:00:00Z",
       end: "2026-02-20T09:30:00Z",
       attendees: ["alice@example.com", "bob@example.com"],
       html_link: "https://calendar.google.com/event?eid=evt_001",
       status: "confirmed"
     }}
  end
end

defmodule Assistant.Integration.MockDrive do
  @moduledoc false

  alias Assistant.Integration.MockCallRecorder

  def list_files(_query, _opts \\ []) do
    MockCallRecorder.record(:drive, :list_files)

    {:ok,
     [
       %{
         id: "file_001",
         name: "Project Roadmap",
         mime_type: "application/vnd.google-apps.document",
         modified_time: "2026-02-19T15:30:00Z",
         size: nil,
         parents: ["folder_root"],
         web_view_link: "https://docs.google.com/document/d/file_001"
       },
       %{
         id: "file_002",
         name: "Budget 2026.xlsx",
         mime_type: "application/vnd.google-apps.spreadsheet",
         modified_time: "2026-02-18T10:00:00Z",
         size: nil,
         parents: ["folder_root"],
         web_view_link: "https://docs.google.com/spreadsheets/d/file_002"
       }
     ]}
  end

  def get_file(_file_id) do
    MockCallRecorder.record(:drive, :get_file)

    {:ok,
     %{
       id: "file_001",
       name: "Project Roadmap",
       mime_type: "application/vnd.google-apps.document",
       modified_time: "2026-02-19T15:30:00Z",
       size: nil,
       parents: ["folder_root"],
       web_view_link: "https://docs.google.com/document/d/file_001"
     }}
  end

  def read_file(_file_id, _opts \\ []) do
    MockCallRecorder.record(:drive, :read_file)
    {:ok, "# Project Roadmap\n\n## Q1 Goals\n- Launch v2.0\n- Improve performance by 30%\n"}
  end

  def create_file(_name, _content, _opts \\ []) do
    MockCallRecorder.record(:drive, :create_file)

    {:ok,
     %{
       id: "file_new_001",
       name: "New Document",
       web_view_link: "https://docs.google.com/document/d/file_new_001"
     }}
  end

  def update_file_content(_file_id, _content, _mime_type \\ "text/plain") do
    MockCallRecorder.record(:drive, :update_file_content)

    {:ok,
     %{
       id: "file_001",
       name: "Project Roadmap",
       web_view_link: "https://docs.google.com/document/d/file_001"
     }}
  end

  def move_file(_file_id, _new_parent_id, _remove_parents \\ true) do
    MockCallRecorder.record(:drive, :move_file)
    {:ok, %{id: "file_001", name: "Project Roadmap", parents: ["folder_archive"]}}
  end

  def type_to_mime(type) do
    types = %{
      "doc" => "application/vnd.google-apps.document",
      "document" => "application/vnd.google-apps.document",
      "sheet" => "application/vnd.google-apps.spreadsheet",
      "spreadsheet" => "application/vnd.google-apps.spreadsheet",
      "pdf" => "application/pdf",
      "folder" => "application/vnd.google-apps.folder"
    }

    case Map.fetch(types, String.downcase(type)) do
      {:ok, mime} -> {:ok, mime}
      :error -> :error
    end
  end

  def google_workspace_type?(mime_type) when is_binary(mime_type) do
    String.starts_with?(mime_type, "application/vnd.google-apps.")
  end

  def google_workspace_type?(_), do: false
end

defmodule Assistant.Integration.MockOpenRouter do
  @moduledoc false

  alias Assistant.Integration.MockCallRecorder

  def image_generation(_prompt, _opts \\ []) do
    MockCallRecorder.record(:openrouter, :image_generation)

    {:ok,
     %{
       id: "gen_001",
       model: "openai/gpt-5-image-mini",
       content: "Generated image of a sunset over mountains.",
       images: [
         %{
           type: "image_url",
           url: "https://example.com/generated/sunset.png",
           mime_type: "image/png"
         }
       ],
       finish_reason: "stop",
       usage: %{prompt_tokens: 50, completion_tokens: 100, total_tokens: 150}
     }}
  end

  def chat_completion(_messages, _opts \\ []) do
    MockCallRecorder.record(:openrouter, :chat_completion)

    {:ok,
     %{
       id: "chat_001",
       model: "openai/gpt-5-mini",
       content: "This is a mock response.",
       tool_calls: [],
       finish_reason: "stop",
       usage: %{prompt_tokens: 10, completion_tokens: 20, total_tokens: 30}
     }}
  end
end

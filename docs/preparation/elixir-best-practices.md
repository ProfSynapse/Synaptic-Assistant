# Elixir Coding Best Practices

> Reference guide for all specialists working on the Skills-First AI Assistant.
> Practical code examples over theory. Organized by topic for quick lookup.

---

## Table of Contents

1. [Naming Conventions and Style](#1-naming-conventions-and-style)
2. [Module Structure](#2-module-structure)
3. [Pattern Matching and Control Flow](#3-pattern-matching-and-control-flow)
4. [Error Handling](#4-error-handling)
5. [OTP Patterns](#5-otp-patterns)
6. [Phoenix and Ecto](#6-phoenix-and-ecto)
7. [Testing](#7-testing)
8. [Concurrency Patterns](#8-concurrency-patterns)
9. [HTTP Clients (Req)](#9-http-clients-req)
10. [Security Practices](#10-security-practices)
11. [Anti-Patterns to Avoid](#11-anti-patterns-to-avoid)
12. [Project-Specific Conventions](#12-project-specific-conventions)

---

## 1. Naming Conventions and Style

### Naming Rules

| Element | Convention | Example |
|---------|-----------|---------|
| Modules | CamelCase, acronyms uppercase | `MyApp.HTTPClient`, `MyApp.LLMClient` |
| Functions, variables, attributes | snake_case | `def fetch_user(user_id)`, `@max_retries` |
| Predicate functions | Trailing `?` | `def valid?(changeset)` |
| Guard-safe predicates | `is_` prefix | `defmacro is_admin(user)` |
| Private functions | `defp` (not underscore prefix) | `defp do_parse(input)` |
| Unused variables | Leading underscore | `_unused`, `_conn` |

### Pipe Operator

Start pipe chains with a "pure" value, not a function call:

```elixir
# Good - clear data flow
username
|> String.trim()
|> String.downcase()
|> validate_username()

# Avoid - less readable start
String.trim(username)
|> String.downcase()
|> validate_username()
```

### Documentation

```elixir
defmodule Assistant.Skills.Drive.ReadFile do
  @moduledoc """
  Skill for reading files from Google Drive.

  Downloads a file by ID and returns its content as binary data.
  Supports Google Workspace export (Docs -> docx, Sheets -> xlsx).
  """

  @doc """
  Reads a file from Google Drive.

  ## Parameters
    - `params` - Map with `:file_id` (required) and `:export_format` (optional)
    - `context` - Skill execution context with auth credentials

  ## Returns
    - `{:ok, %SkillResult{}}` on success
    - `{:error, reason}` on failure
  """
  @spec execute(map(), SkillContext.t()) :: {:ok, SkillResult.t()} | {:error, term()}
  def execute(params, context) do
    # ...
  end
end
```

Use `@moduledoc false` for internal modules that are not part of the public API.

---

## 2. Module Structure

### Recommended Order Within a Module

```elixir
defmodule Assistant.Orchestrator.Engine do
  @moduledoc """
  Main orchestration engine for the AI assistant.
  """

  # 1. use/import/alias/require
  use GenServer
  alias Assistant.Skills.{Registry, Executor}
  alias Assistant.Orchestrator.{Context, Limits}
  require Logger

  # 2. Module attributes and constants
  @max_iterations 25
  @default_timeout :timer.seconds(30)

  # 3. Type definitions
  @type state :: %{
    conversation_id: String.t(),
    messages: [map()],
    iteration_count: non_neg_integer()
  }

  # 4. Behaviour callbacks (if implementing a behaviour)
  @behaviour Assistant.Skill

  # 5. Public API (client functions)
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple(opts[:conversation_id]))
  end

  def process_message(pid, message) do
    GenServer.call(pid, {:process, message}, @default_timeout)
  end

  # 6. Callback implementations
  @impl true
  def init(opts) do
    {:ok, initial_state(opts)}
  end

  @impl true
  def handle_call({:process, message}, _from, state) do
    # ...
  end

  # 7. Private functions
  defp initial_state(opts) do
    # ...
  end
end
```

### File Size

Keep modules under 300 lines. If a module grows beyond that, extract sub-modules:

```elixir
# Instead of one massive module:
# lib/assistant/orchestrator/engine.ex (500+ lines)

# Split into focused modules:
# lib/assistant/orchestrator/engine.ex      (core GenServer, ~150 lines)
# lib/assistant/orchestrator/context.ex     (context assembly, ~100 lines)
# lib/assistant/orchestrator/limits.ex      (iteration tracking, ~80 lines)
# lib/assistant/orchestrator/tool_dispatch.ex (skill routing, ~100 lines)
```

---

## 3. Pattern Matching and Control Flow

### Use Pattern Matching Over Conditionals

```elixir
# Good - pattern match in function heads
def handle_response({:ok, %{status: 200, body: body}}) do
  {:ok, Jason.decode!(body)}
end

def handle_response({:ok, %{status: 429}}) do
  {:error, :rate_limited}
end

def handle_response({:ok, %{status: status}}) when status >= 400 do
  {:error, {:http_error, status}}
end

def handle_response({:error, reason}) do
  {:error, {:connection_error, reason}}
end

# Avoid - nested conditionals
def handle_response(result) do
  case result do
    {:ok, response} ->
      if response.status == 200 do
        {:ok, Jason.decode!(response.body)}
      else
        if response.status == 429 do
          {:error, :rate_limited}
        else
          {:error, {:http_error, response.status}}
        end
      end
    {:error, reason} ->
      {:error, {:connection_error, reason}}
  end
end
```

### `with` for Multi-Step Operations

Use `with` when you have a sequence of operations that all need to succeed:

```elixir
# Good - clear happy path with explicit error handling
def update_file(file_id, new_content, context) do
  with {:ok, original} <- Drive.download(file_id, context),
       {:ok, workspace_path} <- Workspace.create(context.execution_id),
       :ok <- File.write(Path.join(workspace_path, "original"), original),
       {:ok, result} <- transform(new_content, workspace_path),
       {:ok, _archived} <- FileVersionManager.archive(file_id, context),
       {:ok, new_file} <- Drive.upload(result, file_id, context) do
    {:ok, new_file}
  else
    {:error, :not_found} -> {:error, "File not found on Drive"}
    {:error, :permission_denied} -> {:error, "Insufficient permissions"}
    {:error, reason} -> {:error, "File update failed: #{inspect(reason)}"}
  end
end

# Avoid - deeply nested case statements
def update_file(file_id, new_content, context) do
  case Drive.download(file_id, context) do
    {:ok, original} ->
      case Workspace.create(context.execution_id) do
        {:ok, path} ->
          case File.write(...) do
            # 6 levels of nesting...
          end
        {:error, reason} -> {:error, reason}
      end
    {:error, reason} -> {:error, reason}
  end
end
```

### Guard Clauses

```elixir
# Good - use guards for type/value constraints
def set_iteration_limit(limit) when is_integer(limit) and limit > 0 and limit <= 100 do
  {:ok, limit}
end

def set_iteration_limit(_), do: {:error, :invalid_limit}
```

---

## 4. Error Handling

### Tagged Tuples (Primary Pattern)

Use `{:ok, result}` / `{:error, reason}` for expected outcomes:

```elixir
# Good - explicit tagged tuples
def execute_skill(skill_module, params, context) do
  case skill_module.execute(params, context) do
    {:ok, result} -> {:ok, result}
    {:error, :timeout} -> {:error, "Skill timed out after #{context.timeout}ms"}
    {:error, reason} -> {:error, "Skill failed: #{inspect(reason)}"}
  end
end
```

### Exceptions (Only for Truly Exceptional Cases)

```elixir
# Good - exceptions for programmer errors, not expected failures
def fetch_skill!(name) do
  case Registry.lookup(name) do
    {:ok, skill} -> skill
    {:error, :not_found} -> raise "Skill #{name} not registered. Did you forget to add it?"
  end
end

# Avoid - using try/rescue for control flow
def read_config(path) do
  # BAD
  try do
    File.read!(path)
  rescue
    e in File.Error -> {:error, e.reason}
  end

  # GOOD
  File.read(path)
end
```

### Let It Crash (Within Supervision)

```elixir
# Good - let supervised processes crash on unrecoverable errors
defmodule Assistant.Channels.Telegram do
  use GenServer

  @impl true
  def handle_info({:webhook, payload}, state) do
    # If parsing fails, the supervisor restarts us - that's fine
    message = parse_webhook!(payload)
    {:noreply, process_message(message, state)}
  end

  # But handle EXPECTED errors gracefully
  @impl true
  def handle_info({:send_response, channel_msg_id, text}, state) do
    case Telegex.send_message(state.chat_id, text) do
      {:ok, _msg} -> {:noreply, state}
      {:error, reason} ->
        Logger.warning("Failed to send Telegram message: #{inspect(reason)}")
        {:noreply, state}
    end
  end
end
```

### Logging Best Practices

```elixir
# Good - structured metadata, appropriate levels
Logger.info("Skill executed",
  skill: skill_name,
  duration_ms: duration,
  conversation_id: context.conversation_id
)

Logger.warning("Circuit breaker opened",
  skill: skill_name,
  failure_count: state.failure_count,
  cooldown_ms: state.cooldown
)

Logger.error("File versioning failed at archive step",
  file_id: file_id,
  error: inspect(reason),
  step: :archive
)

# Avoid - unstructured string interpolation
Logger.info("Skill #{name} executed in #{duration}ms for conversation #{id}")
```

---

## 5. OTP Patterns

### GenServer

**When to use**: Managing state that needs concurrent access, coordinating work, implementing protocols with message-based communication.

**When NOT to use**: Pure computation with no state (use regular functions), read-heavy caches (use ETS).

```elixir
defmodule Assistant.Resilience.CircuitBreaker do
  @moduledoc """
  Per-skill circuit breaker. Tracks failures and opens/closes the circuit.

  States: :closed (normal) -> :open (blocking) -> :half_open (testing)
  """
  use GenServer

  @failure_threshold 5
  @cooldown_ms :timer.seconds(30)

  # --- Public API (client functions) ---

  def start_link(opts) do
    skill_name = Keyword.fetch!(opts, :skill_name)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(skill_name))
  end

  @doc "Check if the circuit allows execution"
  def allow?(skill_name) do
    GenServer.call(via_tuple(skill_name), :allow?)
  end

  @doc "Record a successful execution"
  def record_success(skill_name) do
    GenServer.cast(via_tuple(skill_name), :success)
  end

  @doc "Record a failed execution"
  def record_failure(skill_name) do
    GenServer.cast(via_tuple(skill_name), :failure)
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    state = %{
      skill_name: opts[:skill_name],
      status: :closed,
      failure_count: 0,
      last_failure_at: nil
    }
    {:ok, state}
  end

  @impl true
  def handle_call(:allow?, _from, %{status: :closed} = state) do
    {:reply, true, state}
  end

  def handle_call(:allow?, _from, %{status: :open} = state) do
    if cooldown_elapsed?(state) do
      {:reply, true, %{state | status: :half_open}}
    else
      {:reply, false, state}
    end
  end

  def handle_call(:allow?, _from, %{status: :half_open} = state) do
    # Allow one test request in half-open state
    {:reply, true, state}
  end

  @impl true
  def handle_cast(:success, state) do
    {:noreply, %{state | status: :closed, failure_count: 0}}
  end

  def handle_cast(:failure, state) do
    new_count = state.failure_count + 1
    new_status = if new_count >= @failure_threshold, do: :open, else: state.status

    if new_status == :open and state.status != :open do
      Logger.warning("Circuit breaker OPENED", skill: state.skill_name, failures: new_count)
    end

    {:noreply, %{state | failure_count: new_count, status: new_status, last_failure_at: now()}}
  end

  # --- Private ---

  defp via_tuple(skill_name), do: {:via, Registry, {Assistant.Registry, {:circuit_breaker, skill_name}}}
  defp cooldown_elapsed?(%{last_failure_at: t}), do: System.monotonic_time(:millisecond) - t > @cooldown_ms
  defp now, do: System.monotonic_time(:millisecond)
end
```

### Supervisor Trees

```elixir
defmodule Assistant.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Infrastructure (start first)
      Assistant.Repo,
      {Registry, keys: :unique, name: Assistant.Registry},

      # Core services
      {Task.Supervisor, name: Assistant.SkillTaskSupervisor},
      Assistant.Skills.Registry,
      Assistant.Notifications.Router,

      # Channel adapters (can crash independently)
      {Supervisor, name: Assistant.ChannelSupervisor, strategy: :one_for_one, children: [
        Assistant.Channels.GoogleChat,
        Assistant.Channels.Telegram
      ]},

      # Web endpoint (last - depends on everything above)
      AssistantWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Assistant.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

**Supervisor strategies**:

| Strategy | When to Use |
|----------|------------|
| `:one_for_one` | Children are independent (default choice) |
| `:one_for_all` | Children are interdependent (all restart if one fails) |
| `:rest_for_one` | Later children depend on earlier ones |

### Task.Supervisor for Skill Execution

```elixir
defmodule Assistant.Skills.Executor do
  @moduledoc """
  Executes skills as supervised async tasks with timeouts.
  """

  @default_timeout :timer.seconds(30)

  def execute(skill_module, params, context, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    task = Task.Supervisor.async_nolink(
      Assistant.SkillTaskSupervisor,
      fn -> skill_module.execute(params, context) end
    )

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, result}} ->
        {:ok, result}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:exit, reason} ->
        Logger.error("Skill crashed", skill: skill_module, reason: inspect(reason))
        {:error, {:skill_crash, reason}}

      nil ->
        Logger.warning("Skill timed out", skill: skill_module, timeout: timeout)
        {:error, :timeout}
    end
  end
end
```

### Agent (Use Sparingly)

Agents are a subset of GenServers. Prefer GenServer for anything non-trivial:

```elixir
# Acceptable - simple shared counter or cache
defmodule Assistant.Stats do
  use Agent

  def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
  def increment(key), do: Agent.update(__MODULE__, &Map.update(&1, key, 1, fn n -> n + 1 end))
  def get(key), do: Agent.get(__MODULE__, &Map.get(&1, key, 0))
end

# For anything more complex, use GenServer instead
```

---

## 6. Phoenix and Ecto

### Contexts (Bounded Domains)

Group related functionality into contexts. Each context is a public API boundary:

```elixir
# Good - context encapsulates domain logic
defmodule Assistant.Conversations do
  @moduledoc "Public API for conversation management."

  alias Assistant.Repo
  alias Assistant.Schemas.{Conversation, Message}

  def create_conversation(attrs) do
    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  def add_message(conversation_id, attrs) do
    %Message{conversation_id: conversation_id}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end

  def get_recent_messages(conversation_id, limit \\ 20) do
    Message
    |> where(conversation_id: ^conversation_id)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end
end
```

### Ecto Schemas and Changesets

```elixir
defmodule Assistant.Schemas.FileVersion do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "file_versions" do
    field :original_drive_file_id, :string
    field :archived_drive_file_id, :string
    field :new_drive_file_id, :string
    field :original_filename, :string
    field :version_number, :integer
    field :operation_type, :string
    field :skill_name, :string
    field :file_hash_before, :string
    field :file_hash_after, :string
    field :metadata, :map, default: %{}

    belongs_to :user, Assistant.Schemas.User, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:original_drive_file_id, :original_filename, :version_number, :operation_type]
  @optional_fields [:archived_drive_file_id, :new_drive_file_id, :skill_name,
                    :file_hash_before, :file_hash_after, :metadata, :user_id]

  def changeset(file_version, attrs) do
    file_version
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:operation_type, ~w(skill_edit user_upload system_migration))
    |> validate_number(:version_number, greater_than: 0)
  end
end
```

### Ecto Queries

```elixir
# Good - composable query functions
defmodule Assistant.Schemas.Message do
  import Ecto.Query

  def for_conversation(query \\ __MODULE__, conversation_id) do
    where(query, conversation_id: ^conversation_id)
  end

  def recent(query \\ __MODULE__, limit) do
    query
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
  end

  def with_role(query \\ __MODULE__, role) do
    where(query, role: ^role)
  end
end

# Usage - compose queries cleanly
messages =
  Message
  |> Message.for_conversation(conv_id)
  |> Message.with_role("user")
  |> Message.recent(10)
  |> Repo.all()
```

### Migrations

```elixir
defmodule Assistant.Repo.Migrations.CreateFileVersions do
  use Ecto.Migration

  def change do
    create table(:file_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :original_drive_file_id, :text, null: false
      add :archived_drive_file_id, :text
      add :new_drive_file_id, :text
      add :original_filename, :text, null: false
      add :version_number, :integer, null: false
      add :operation_type, :text, null: false
      add :skill_name, :text
      add :file_hash_before, :text
      add :file_hash_after, :text
      add :metadata, :map, default: %{}
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:file_versions, [:original_drive_file_id])
    create index(:file_versions, [:inserted_at])
  end
end
```

### Controllers (Webhook Handlers)

```elixir
defmodule AssistantWeb.TelegramController do
  use AssistantWeb, :controller

  action_fallback AssistantWeb.FallbackController

  def webhook(conn, params) do
    with {:ok, message} <- parse_update(params),
         :ok <- Assistant.Channels.Telegram.handle_message(message) do
      # Telegram expects 200 OK quickly - processing happens async
      send_resp(conn, 200, "ok")
    end
  end

  defp parse_update(%{"message" => msg}) when is_map(msg) do
    {:ok, normalize_message(msg)}
  end

  defp parse_update(_), do: {:error, :unrecognized_update}
end

# Centralized error handling
defmodule AssistantWeb.FallbackController do
  use AssistantWeb, :controller

  def call(conn, {:error, :unrecognized_update}) do
    send_resp(conn, 200, "ok")  # Don't retry unrecognized updates
  end

  def call(conn, {:error, :unauthorized}) do
    conn |> put_status(401) |> json(%{error: "unauthorized"})
  end

  def call(conn, {:error, _reason}) do
    conn |> put_status(500) |> json(%{error: "internal_error"})
  end
end
```

---

## 7. Testing

### ExUnit Structure

```elixir
defmodule Assistant.Skills.ExecutorTest do
  use Assistant.DataCase, async: true  # async: true when tests don't share state

  alias Assistant.Skills.Executor

  describe "execute/3" do
    test "returns skill result on success" do
      skill = MockSkill  # Mox mock
      params = %{query: "test"}
      context = build_context()

      Mox.expect(MockSkill, :execute, fn ^params, ^context ->
        {:ok, %SkillResult{status: :ok, content: "result"}}
      end)

      assert {:ok, %SkillResult{content: "result"}} = Executor.execute(skill, params, context)
    end

    test "returns error on timeout" do
      Mox.expect(MockSkill, :execute, fn _, _ ->
        Process.sleep(:infinity)  # Simulate hang
      end)

      assert {:error, :timeout} = Executor.execute(MockSkill, %{}, build_context(), timeout: 100)
    end

    test "returns error when skill crashes" do
      Mox.expect(MockSkill, :execute, fn _, _ ->
        raise "boom"
      end)

      assert {:error, {:skill_crash, _}} = Executor.execute(MockSkill, %{}, build_context())
    end
  end

  defp build_context do
    %SkillContext{
      conversation_id: "test_conv",
      execution_id: "test_exec",
      user_id: "test_user"
    }
  end
end
```

### Mox (Behaviour-Based Mocking)

Setup in `test/support/mocks.ex`:

```elixir
# Define mocks for all behaviours
Mox.defmock(MockLLMClient, for: Assistant.Orchestrator.LLMClient)
Mox.defmock(MockSkill, for: Assistant.Skill)
Mox.defmock(MockDriveClient, for: Assistant.Integrations.Google.DriveClient)
Mox.defmock(MockChannelAdapter, for: Assistant.Channels.Adapter)
```

Configure in `config/test.exs`:

```elixir
# Replace real implementations with mocks in test
config :assistant, :llm_client, MockLLMClient
config :assistant, :drive_client, MockDriveClient
```

Use in production code via application config:

```elixir
defmodule Assistant.Orchestrator.Engine do
  # Fetch implementation at compile time (real or mock)
  @llm_client Application.compile_env(:assistant, :llm_client, Assistant.Integrations.OpenRouter)

  defp call_llm(messages, tools) do
    @llm_client.chat_completion(messages, tools)
  end
end
```

Testing with Mox:

```elixir
defmodule Assistant.Orchestrator.EngineTest do
  use Assistant.DataCase, async: true
  import Mox

  setup :verify_on_exit!

  test "agent loop terminates within iteration limit" do
    # First call returns a tool call
    expect(MockLLMClient, :chat_completion, fn _msgs, _tools ->
      {:ok, %{tool_calls: [%{name: "search", arguments: %{q: "test"}}]}}
    end)

    # Second call returns final answer (no tool calls)
    expect(MockLLMClient, :chat_completion, fn _msgs, _tools ->
      {:ok, %{content: "Here are the results.", tool_calls: []}}
    end)

    expect(MockSkill, :execute, fn %{q: "test"}, _ctx ->
      {:ok, %SkillResult{content: "found 3 results"}}
    end)

    assert {:ok, response} = Engine.process("search for test", context)
    assert response.content == "Here are the results."
  end
end
```

### Bypass (HTTP Mocking)

For testing HTTP integrations without Mox (useful for integration tests):

```elixir
defmodule Assistant.Integrations.OpenRouterTest do
  use ExUnit.Case, async: true

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  test "chat_completion returns parsed response", %{bypass: bypass, base_url: base_url} do
    Bypass.expect(bypass, "POST", "/api/v1/chat/completions", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{
        choices: [%{message: %{content: "Hello!", tool_calls: []}}]
      }))
    end)

    client = OpenRouter.new(base_url: base_url, api_key: "test")
    assert {:ok, %{content: "Hello!"}} = OpenRouter.chat_completion(client, messages, tools)
  end
end
```

### Property-Based Testing (StreamData)

```elixir
defmodule Assistant.Orchestrator.LimitsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  property "iteration count never exceeds configured maximum" do
    check all max_iterations <- integer(1..100),
              num_calls <- integer(0..200) do
      limits = Limits.new(max_iterations: max_iterations)

      {final_limits, halted?} =
        Enum.reduce(1..num_calls, {limits, false}, fn _, {lim, _halted} ->
          case Limits.check_and_increment(lim) do
            {:ok, new_lim} -> {new_lim, false}
            {:error, :limit_exceeded} -> {lim, true}
          end
        end)

      assert final_limits.count <= max_iterations
      if num_calls > max_iterations, do: assert(halted?)
    end
  end
end
```

### Test Organization

```
test/
  assistant/
    channels/
      telegram_test.exs           # Unit: message parsing, normalization
    orchestrator/
      engine_test.exs             # Unit: agent loop logic (mocked LLM)
      limits_test.exs             # Unit: iteration limit enforcement
    skills/
      executor_test.exs           # Unit: task supervision, timeout
      registry_test.exs           # Unit: skill discovery
      drive/
        read_file_test.exs        # Unit: skill logic (mocked Drive client)
    files/
      version_manager_test.exs    # Integration: PULL/ARCHIVE/REPLACE workflow
    resilience/
      circuit_breaker_test.exs    # Unit: state transitions
  assistant_web/
    controllers/
      telegram_controller_test.exs  # Integration: webhook handling
      health_controller_test.exs
  support/
    mocks.ex                      # Mox mock definitions
    fixtures.ex                   # Factory functions
    data_case.ex                  # Database test setup
```

---

## 8. Concurrency Patterns

### Parallel Skill Execution

When the LLM requests multiple tool calls in one response:

```elixir
def execute_parallel(tool_calls, context) do
  tool_calls
  |> Enum.map(fn tool_call ->
    Task.Supervisor.async_nolink(
      Assistant.SkillTaskSupervisor,
      fn -> execute_single(tool_call, context) end
    )
  end)
  |> Task.yield_many(:timer.seconds(30))
  |> Enum.zip(tool_calls)
  |> Enum.map(fn
    {{:ok, {:ok, result}}, tool_call} ->
      %{tool_call_id: tool_call.id, result: result}

    {{:ok, {:error, reason}}, tool_call} ->
      %{tool_call_id: tool_call.id, error: inspect(reason)}

    {{:exit, reason}, tool_call} ->
      %{tool_call_id: tool_call.id, error: "crashed: #{inspect(reason)}"}

    {nil, tool_call} ->
      # Timed out - shut down the task
      %{tool_call_id: tool_call.id, error: "timed out"}
  end)
end
```

### ETS for Read-Heavy Data

Use ETS when a GenServer becomes a bottleneck for reads:

```elixir
defmodule Assistant.Skills.Registry do
  @moduledoc """
  Discovers and registers available skills in an ETS table.
  GenServer handles writes; ETS handles reads (no bottleneck).
  """
  use GenServer

  @table_name :skill_registry

  # Public API - reads go directly to ETS (no GenServer bottleneck)
  def lookup(skill_name) do
    case :ets.lookup(@table_name, skill_name) do
      [{^skill_name, module, definition}] -> {:ok, {module, definition}}
      [] -> {:error, :not_found}
    end
  end

  def all_definitions do
    :ets.tab2list(@table_name)
    |> Enum.map(fn {_name, _module, definition} -> definition end)
  end

  # GenServer manages writes
  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:named_table, :set, read_concurrency: true])
    register_all_skills(table)
    {:ok, %{table: table}}
  end

  defp register_all_skills(table) do
    for module <- discover_skills() do
      definition = module.tool_definition()
      :ets.insert(table, {definition.name, module, definition})
    end
  end

  defp discover_skills do
    # Module discovery at startup
    {:ok, modules} = :application.get_key(:assistant, :modules)
    Enum.filter(modules, &implements_skill_behaviour?/1)
  end
end
```

### Process Registry (via Registry)

Use Elixir's built-in `Registry` instead of named processes for dynamic lookups:

```elixir
# Registration
def start_link(opts) do
  conversation_id = Keyword.fetch!(opts, :conversation_id)
  GenServer.start_link(__MODULE__, opts,
    name: {:via, Registry, {Assistant.Registry, {:conversation, conversation_id}}}
  )
end

# Lookup
def get_engine(conversation_id) do
  case Registry.lookup(Assistant.Registry, {:conversation, conversation_id}) do
    [{pid, _value}] -> {:ok, pid}
    [] -> {:error, :not_found}
  end
end
```

---

## 9. HTTP Clients (Req)

### Building API Clients with Req

```elixir
defmodule Assistant.Integrations.OpenRouter do
  @moduledoc """
  OpenRouter API client for LLM chat completions with tool calling.
  """
  @behaviour Assistant.Orchestrator.LLMClient

  @base_url "https://openrouter.ai/api/v1"

  def new(opts \\ []) do
    Req.new(
      base_url: Keyword.get(opts, :base_url, @base_url),
      headers: [
        {"authorization", "Bearer #{api_key()}"},
        {"content-type", "application/json"}
      ],
      retry: :safe_transient,          # Retry 429/500/502/503/504
      max_retries: 3,
      retry_delay: &retry_delay/1,     # Exponential backoff with Retry-After
      receive_timeout: :timer.seconds(60)
    )
  end

  @impl true
  def chat_completion(messages, tools, opts \\ []) do
    model = Keyword.get(opts, :model, "openrouter/auto")

    body = %{
      model: model,
      messages: messages,
      tools: format_tools(tools),
      tool_choice: "auto"
    }

    case Req.post(new(), url: "/chat/completions", json: body) do
      {:ok, %{status: 200, body: body}} ->
        parse_completion(body)

      {:ok, %{status: 429, headers: headers}} ->
        retry_after = get_retry_after(headers)
        {:error, {:rate_limited, retry_after}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:connection_error, reason}}
    end
  end

  defp api_key, do: Application.fetch_env!(:assistant, :openrouter_api_key)

  defp retry_delay(n), do: Integer.pow(2, n) * 1_000  # 1s, 2s, 4s

  defp format_tools(tools) do
    Enum.map(tools, fn tool ->
      %{type: "function", function: tool}
    end)
  end
end
```

### Streaming Responses

```elixir
def chat_completion_stream(messages, tools, callback) do
  body = %{model: "openrouter/auto", messages: messages, tools: format_tools(tools), stream: true}

  Req.post(new(),
    url: "/chat/completions",
    json: body,
    into: fn {:data, data}, {req, resp} ->
      # Parse SSE chunks
      data
      |> String.split("\n")
      |> Enum.each(fn
        "data: [DONE]" -> :ok
        "data: " <> json ->
          case Jason.decode(json) do
            {:ok, chunk} -> callback.(chunk)
            _ -> :ok
          end
        _ -> :ok
      end)

      {:cont, {req, resp}}
    end
  )
end
```

---

## 10. Security Practices

### Credential Management

```elixir
# Good - runtime environment variables, never compile-time
# config/runtime.exs
config :assistant,
  openrouter_api_key: System.fetch_env!("OPENROUTER_API_KEY"),
  google_credentials: System.fetch_env!("GOOGLE_APPLICATION_CREDENTIALS")

# Never log credentials
Logger.info("Connecting to OpenRouter", model: model)  # Good
Logger.info("API key: #{api_key}")                      # NEVER DO THIS
```

### Webhook Signature Verification

```elixir
defmodule AssistantWeb.Plugs.WebhookVerification do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    channel = Keyword.fetch!(opts, :channel)

    case verify_signature(conn, channel) do
      :ok -> conn
      :error ->
        conn
        |> send_resp(401, "invalid signature")
        |> halt()
    end
  end

  defp verify_signature(conn, :telegram) do
    # Telegram uses a secret_token header
    expected = Application.fetch_env!(:assistant, :telegram_webhook_secret)
    actual = get_req_header(conn, "x-telegram-bot-api-secret-token") |> List.first()

    if Plug.Crypto.secure_compare(expected || "", actual || ""), do: :ok, else: :error
  end
end
```

### Input Validation

```elixir
# Validate all external input at system boundaries
def handle_tool_call(%{"name" => name, "arguments" => args}) when is_binary(name) and is_map(args) do
  with {:ok, {skill_module, definition}} <- Registry.lookup(name),
       {:ok, validated_args} <- validate_arguments(args, definition.parameters) do
    {:ok, skill_module, validated_args}
  end
end

def handle_tool_call(_), do: {:error, :invalid_tool_call}
```

### Ecto Changeset for Mass Assignment Protection

```elixir
# Always use changesets to control which fields can be set externally
def changeset(struct, attrs) do
  struct
  |> cast(attrs, [:name, :email])           # Only these fields from external input
  # :is_admin, :role, etc. are NEVER in this list
  |> validate_required([:name, :email])
end
```

### Redact Sensitive Fields

```elixir
defmodule Assistant.Schemas.User do
  use Ecto.Schema

  schema "users" do
    field :email, :string
    field :api_token, :string, redact: true       # Won't appear in inspect/logs
    field :google_refresh_token, :string, redact: true
  end
end
```

---

## 11. Anti-Patterns to Avoid

### Process Anti-Patterns

**1. Using GenServer for Pure Computation**

```elixir
# BAD - GenServer for stateless math
defmodule Calculator do
  use GenServer
  def add(a, b, pid), do: GenServer.call(pid, {:add, a, b})
  def handle_call({:add, a, b}, _from, state), do: {:reply, a + b, state}
end

# GOOD - plain module
defmodule Calculator do
  def add(a, b), do: a + b
end
```

**2. GenServer as Bottleneck**

```elixir
# BAD - long-running work in handle_call blocks all other messages
def handle_call({:process, data}, _from, state) do
  result = expensive_api_call(data)  # Blocks for seconds
  {:reply, result, state}
end

# GOOD - delegate to Task, respond asynchronously
def handle_call({:process, data}, from, state) do
  Task.Supervisor.async_nolink(Assistant.SkillTaskSupervisor, fn ->
    result = expensive_api_call(data)
    GenServer.reply(from, result)
  end)
  {:noreply, state}
end
```

**3. Sending Unnecessary Data Between Processes**

```elixir
# BAD - copies entire conn struct to spawned process
spawn(fn -> log_request(conn) end)

# GOOD - extract only what's needed
ip = conn.remote_ip
path = conn.request_path
spawn(fn -> log_request(ip, path) end)
```

**4. Unsupervised Processes**

```elixir
# BAD - process outside supervision tree
Task.start(fn -> do_work() end)

# GOOD - supervised
Task.Supervisor.start_child(Assistant.SkillTaskSupervisor, fn -> do_work() end)
```

### Design Anti-Patterns

**5. Exceptions for Control Flow**

```elixir
# BAD
try do
  File.read!(path)
rescue
  e in File.Error -> {:error, e.reason}
end

# GOOD
case File.read(path) do
  {:ok, content} -> {:ok, content}
  {:error, reason} -> {:error, reason}
end
```

**6. Primitive Obsession**

```elixir
# BAD - passing raw strings around
def process_message(text, channel, user_id, timestamp) do ...

# GOOD - use structs
def process_message(%ConversationMessage{} = message) do ...
```

**7. Boolean Obsession**

```elixir
# BAD - overlapping booleans
def handle(msg, is_admin: true, is_editor: false) do ...

# GOOD - use atoms
def handle(msg, role: :admin) do ...
```

**8. Scattered GenServer Calls**

```elixir
# BAD - GenServer.call scattered across many modules
defmodule ModuleA do
  def do_thing(pid), do: GenServer.call(pid, :thing)
end

defmodule ModuleB do
  def do_other(pid), do: GenServer.call(pid, :other)
end

# GOOD - centralize all interaction in the GenServer's own module
defmodule MyServer do
  def do_thing(pid), do: GenServer.call(pid, :thing)
  def do_other(pid), do: GenServer.call(pid, :other)
  # All handle_call clauses here too
end
```

**9. Using Application Config for Dependency Injection**

```elixir
# BAD - runtime Application.get_env in hot path
def call_llm(messages) do
  client = Application.get_env(:assistant, :llm_client)  # Called every time
  client.chat_completion(messages)
end

# GOOD - compile-time module attribute
@llm_client Application.compile_env(:assistant, :llm_client, Assistant.Integrations.OpenRouter)

def call_llm(messages) do
  @llm_client.chat_completion(messages)
end
```

---

## 12. Project-Specific Conventions

### Behaviour-First Design

Every external integration MUST have a behaviour:

```elixir
# Define the contract
defmodule Assistant.Orchestrator.LLMClient do
  @callback chat_completion(messages :: [map()], tools :: [map()], opts :: keyword()) ::
    {:ok, map()} | {:error, term()}
end

# Implement it
defmodule Assistant.Integrations.OpenRouter do
  @behaviour Assistant.Orchestrator.LLMClient
  @impl true
  def chat_completion(messages, tools, opts \\ []) do
    # ...
  end
end

# Mock it in tests
Mox.defmock(MockLLMClient, for: Assistant.Orchestrator.LLMClient)
```

### Skill Implementation Template

Every skill follows this pattern:

```elixir
defmodule Assistant.Skills.Drive.UpdateFile do
  @moduledoc """
  Updates a file on Google Drive using non-destructive versioning.
  """
  @behaviour Assistant.Skill

  @impl true
  def tool_definition do
    %{
      name: "update_drive_file",
      description: "Update an existing file on Google Drive. Archives the old version automatically.",
      parameters: %{
        type: "object",
        properties: %{
          file_id: %{type: "string", description: "Google Drive file ID"},
          content: %{type: "string", description: "New file content"}
        },
        required: ["file_id", "content"]
      }
    }
  end

  @impl true
  def domain, do: :drive

  @impl true
  def execute(params, context) do
    with {:ok, result} <- Assistant.Files.VersionManager.update(
           params["file_id"],
           params["content"],
           context
         ) do
      {:ok, %SkillResult{
        status: :ok,
        content: "File updated successfully. Version #{result.version_number} archived.",
        side_effects: [:file_updated],
        metadata: %{new_file_id: result.new_drive_file_id}
      }}
    end
  end
end
```

### File Versioning Invariant

The PULL-MANIPULATE-ARCHIVE-REPLACE workflow MUST maintain this invariant:

```
INVARIANT: Archive ALWAYS happens before Replace.
INVARIANT: No file is ever permanently deleted.
INVARIANT: Every operation is logged to file_versions table.
```

If any step fails, the rollback ensures the user's file is never lost.

### Error Notification Convention

All errors that leave the system boundary (API failures, skill crashes, circuit breaker trips) MUST be routed through the `Notifications.Router`:

```elixir
# In skill executor, circuit breaker, file version manager, etc.
Assistant.Notifications.Router.notify(%{
  severity: :error,
  source: "skill:#{skill_name}",
  message: "Skill execution failed",
  error_type: inspect(reason.__struct__),
  context: %{conversation_id: context.conversation_id, skill: skill_name}
})
```

---

## References

- [Elixir Official Style Guide (Credo)](https://github.com/rrrene/elixir-style-guide)
- [Elixir Official Anti-Patterns: Process](https://hexdocs.pm/elixir/process-anti-patterns.html)
- [Elixir Official Anti-Patterns: Design](https://hexdocs.pm/elixir/main/design-anti-patterns.html)
- [GenServer Documentation](https://hexdocs.pm/elixir/GenServer.html)
- [Task Documentation](https://hexdocs.pm/elixir/Task.html)
- [Phoenix Contexts Guide](https://hexdocs.pm/phoenix/contexts.html)
- [Ecto Changeset Documentation](https://hexdocs.pm/ecto/Ecto.Changeset.html)
- [Phoenix Security Guide](https://hexdocs.pm/phoenix/security.html)
- [Mox: Mocks and Explicit Contracts](https://github.com/dashbitco/mox)
- [Req HTTP Client](https://hexdocs.pm/req/Req.html)
- [Elixir for AI Agents](https://elixirator.com/blog/elixir-for-ai-agents/)
- [Orchestrating AI Agents with Elixir](https://www.freshcodeit.com/blog/why-elixir-is-the-best-runtime-for-building-agentic-workflows)

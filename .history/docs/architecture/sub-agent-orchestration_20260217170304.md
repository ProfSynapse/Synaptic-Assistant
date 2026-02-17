# Sub-Agent Orchestration: Architectural Design

> Part of the Skills-First AI Assistant architecture.
> Extends and supersedes the single-loop agentic pattern from `two-tool-architecture.md`.
> Planning only — no implementation.

## 1. Overview

### 1.1 The Shift: From Single-Loop to Multi-Agent

The original two-tool architecture had a single LLM acting as both planner and executor — it called `get_skill` to discover capabilities and `use_skill` to execute them, looping until done. This works for simple requests but has fundamental limitations:

1. **Context pollution**: The orchestrator LLM's context fills with skill execution details (API responses, search results, file contents) that are irrelevant to its planning role. After 5-6 tool calls, most of the context window is consumed by results, degrading planning quality.

2. **No parallelism**: The single-loop model is inherently sequential. "Search tasks AND send an email AND create a calendar event" executes one at a time, each consuming a loop iteration.

3. **No specialization**: Every tool call uses the same system prompt, context window, and model. A complex file manipulation gets the same treatment as a simple email send.

4. **Blast radius**: If one tool call fails or the LLM makes a bad decision mid-loop, the entire turn is compromised. There is no isolation between independent operations.

### 1.2 The Solution: Orchestrator + Sub-Agents

The system splits into two roles:

| Role | Responsibility | Tools Available | Context |
|------|---------------|-----------------|---------|
| **Orchestrator** | Decompose, plan, coordinate, synthesize | `get_skill` + agent management tools | Conversation history + memory + plan |
| **Sub-Agent** | Execute a focused task using skills | `use_skill` (scoped to relevant domains) | Scoped mission + relevant skill schemas |

The orchestrator **never** calls `use_skill` directly. It plans what needs to happen, then delegates execution to sub-agents. Each sub-agent is a fresh LLM call with a focused context window — it knows its mission, the skills available to it, and nothing else.

```
User: "Send Bob the overdue tasks report and schedule a review meeting"

Orchestrator thinks: Two independent sub-tasks.
  1. get_skill(domain: "tasks") -> understands what task search can do
  2. get_skill(domain: "email") -> understands email capabilities
  3. get_skill(domain: "calendar") -> understands calendar capabilities

Orchestrator plans:
  Agent A: Search overdue tasks, compose report, send email to Bob
    -> needs: tasks (search), email (send)
    -> serial: search first, then send with results

  Agent B: Create calendar event for task review with Bob
    -> needs: calendar (create_event)
    -> parallel with Agent A (no dependency)

  [A and B run concurrently]

  Agent A result: "Sent email to bob@co.com with 3 overdue tasks"
  Agent B result: "Created 'Task Review with Bob' on Feb 20 at 2pm"

Orchestrator synthesizes: "Done! I sent Bob an email with the 3 overdue tasks
and scheduled a review meeting for Thursday at 2pm."
```

### 1.3 Design Principles

**Orchestrator coordinates, sub-agents execute.** The orchestrator's context window is reserved for conversation history, memory, and planning. Sub-agents handle the messy details of skill execution.

**Sub-agents are ephemeral.** Each sub-agent is a single LLM call (or a short loop of calls). It starts fresh, executes its mission, and returns a result. No long-lived sub-agent state.

**Parallel by default, serial when required.** Independent sub-tasks run concurrently. Dependencies are explicit — the orchestrator defines which agents must wait for others.

**Scoped context, scoped tools.** Each sub-agent receives only the skill schemas and context relevant to its mission. An email-sending agent never sees calendar or HubSpot tool definitions.

**Fail independently.** A sub-agent failure does not halt other sub-agents. The orchestrator decides how to handle partial failures — retry, skip, or report to user.

---

## 2. Orchestrator Tool Surface

The orchestrator LLM sees **three** tools:

### 2.1 get_skill (Unchanged)

Same as the existing `get_skill` meta-tool. The orchestrator uses it to understand what capabilities exist before planning sub-agent missions.

```elixir
# Unchanged from two-tool-architecture.md
MetaTools.GetSkill.tool_definition()
```

### 2.2 dispatch_agent

```elixir
defmodule Assistant.Orchestrator.Tools.DispatchAgent do
  def tool_definition do
    %{
      name: "dispatch_agent",
      description: """
      Dispatch a sub-agent to execute a focused task. The agent receives the \
      skills it needs and a clear mission. Use this after calling get_skill \
      to understand available capabilities.

      You can dispatch multiple agents at once — they will run in parallel \
      unless you specify dependencies via depends_on.

      Each agent returns a result when complete. Wait for results before \
      responding to the user.
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "agent_id" => %{
            "type" => "string",
            "description" => "A unique identifier for this agent (e.g., 'email_agent', 'task_search'). Used for dependency references."
          },
          "mission" => %{
            "type" => "string",
            "description" => "Clear, specific instructions for what the agent should accomplish. Be explicit about inputs, expected outputs, and success criteria."
          },
          "skills" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "List of skill names the agent can use (e.g., ['tasks.search', 'email.send']). Agent only sees these skills."
          },
          "context" => %{
            "type" => "string",
            "description" => "Additional context the agent needs (e.g., search results from a prior agent, user preferences). Keep concise."
          },
          "depends_on" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Agent IDs this agent must wait for before starting. Their results are injected into this agent's context. Optional — omit for parallel execution."
          },
          "max_tool_calls" => %{
            "type" => "integer",
            "description" => "Maximum tool calls this agent can make. Default: 5. Use higher for complex multi-step tasks."
          }
        },
        "required" => ["agent_id", "mission", "skills"]
      }
    }
  end
end
```

### 2.3 get_agent_results

```elixir
defmodule Assistant.Orchestrator.Tools.GetAgentResults do
  def tool_definition do
    %{
      name: "get_agent_results",
      description: """
      Retrieve results from dispatched agents. Call this after dispatching \
      agents to collect their outputs. Blocks until all specified agents \
      have completed (or timed out).

      If called with no agent_ids, returns results for ALL dispatched agents \
      in the current turn.
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "agent_ids" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "IDs of specific agents to wait for. Omit to wait for all."
          }
        },
        "required" => []
      }
    }
  end
end
```

**Return format**:

```json
{
  "agents": [
    {
      "agent_id": "task_search",
      "status": "completed",
      "result": "Found 3 overdue tasks:\n1. Finalize Q1 report (due Feb 15)\n2. Review PR #42 (due Feb 10)\n3. Update client proposal (due Feb 12)",
      "tool_calls_used": 1,
      "duration_ms": 2340
    },
    {
      "agent_id": "email_sender",
      "status": "completed",
      "result": "Email sent to bob@company.com with subject 'Overdue Tasks Report'",
      "tool_calls_used": 1,
      "duration_ms": 1850
    }
  ]
}
```

Agent status values: `completed`, `failed`, `timeout`, `running`.

---

## 3. Sub-Agent Architecture

### 3.1 Sub-Agent Lifecycle

```
Orchestrator dispatches agent
    |
    v
AgentSupervisor spawns Task
    |
    v
Build sub-agent context:
  - System prompt (focused role)
  - Mission from orchestrator
  - Dependency results (if depends_on)
  - Skill schemas (only specified skills)
  - Additional context string
    |
    v
+--- SUB-AGENT LOOP ---+
|                        |
|  Call OpenRouter       |
|  (with use_skill only) |
|       |                |
|       v                |
|  Response type?        |
|   |          |         |
|   v          v         |
|  text     tool_call    |
|   |          |         |
|   v          v         |
|  DONE    Execute       |
|  (return  use_skill    |
|   text)      |         |
|              v         |
|         Feed result    |
|         back to LLM    |
|              |         |
|         Check limit    |
|          |       |     |
|          v       v     |
|         OK    TRIPPED  |
|          |       |     |
|          +--loop-+     |
|                  |     |
|              Return    |
|              partial   |
|              result    |
+------------------------+
    |
    v
Return result to orchestrator
(via AgentSupervisor callback)
```

### 3.2 Sub-Agent Context Construction

Each sub-agent receives a minimal, focused context:

```elixir
defmodule Assistant.Orchestrator.SubAgent do
  def build_context(dispatch_params, dependency_results, skill_registry) do
    skill_modules = Enum.map(dispatch_params.skills, fn name ->
      {:ok, mod} = Registry.get_by_name(name)
      mod
    end)

    tool_definitions = Enum.map(skill_modules, fn mod ->
      # Sub-agents see use_skill scoped to their allowed skills
      mod.tool_definition()
    end)

    system_prompt = build_sub_agent_prompt(dispatch_params, dependency_results)

    %{
      system: system_prompt,
      messages: [%{role: "user", content: dispatch_params.mission}],
      tools: [build_scoped_use_skill(tool_definitions)]
    }
  end

  defp build_sub_agent_prompt(params, dep_results) do
    base = """
    You are a focused execution agent. Your mission is described below.
    Execute it using the available skills, then return a clear summary of \
    what you accomplished.

    Rules:
    - Use the use_skill tool to execute skills
    - Only use the skills listed in your tool definition
    - Be concise in your final response — the orchestrator will synthesize for the user
    - If a skill fails, report the error clearly — do not retry indefinitely
    - If you cannot complete your mission, explain what blocked you
    """

    context_section = if params.context do
      "\n\nAdditional context:\n#{params.context}"
    else
      ""
    end

    dep_section = if dep_results != [] do
      results_text = Enum.map_join(dep_results, "\n\n", fn {id, result} ->
        "Results from #{id}:\n#{result}"
      end)
      "\n\nResults from prior agents:\n#{results_text}"
    else
      ""
    end

    base <> context_section <> dep_section
  end
end
```

### 3.3 Scoped use_skill

Sub-agents see a single `use_skill` tool, but its description includes the specific skill schemas available to that agent. This is a compile-time scoping — the sub-agent physically cannot invoke skills outside its scope.

```elixir
defp build_scoped_use_skill(skill_definitions) do
  skills_desc = Enum.map_join(skill_definitions, "\n\n", fn defn ->
    params_desc = Jason.encode!(defn.parameters, pretty: true)
    """
    Skill: #{defn.name}
    Description: #{defn.description}
    Parameters: #{params_desc}
    """
  end)

  %{
    name: "use_skill",
    description: """
    Execute a skill. Available skills for this agent:

    #{skills_desc}

    Call with the skill name and arguments matching the schema above.
    """,
    parameters: %{
      "type" => "object",
      "properties" => %{
        "skill" => %{
          "type" => "string",
          "enum" => Enum.map(skill_definitions, & &1.name),
          "description" => "The skill to execute"
        },
        "arguments" => %{
          "type" => "object",
          "description" => "Arguments matching the skill's parameter schema"
        }
      },
      "required" => ["skill", "arguments"]
    }
  }
end
```

**Key difference from the single-loop design**: In the original two-tool architecture, `use_skill` accepted any skill name and validated at runtime. In the sub-agent model, the `use_skill` tool definition includes an `enum` restricting the skill name to only the skills the orchestrator granted. This is enforced at both the tool definition level (LLM sees the enum) and at runtime (the executor validates against the dispatch's skill list).

---

## 4. Dependency Graph and Execution

### 4.1 Dependency Model

The orchestrator defines dependencies between sub-agents via the `depends_on` field. This creates a directed acyclic graph (DAG):

```
Simple parallel (no deps):
  Agent A ----+
              +---> orchestrator collects
  Agent B ----+

Serial chain:
  Agent A --> Agent B --> Agent C

Diamond (mixed):
  Agent A ----+
              +--> Agent C --> Agent D
  Agent B ----+
```

### 4.2 Execution Scheduler

The `AgentScheduler` module manages the DAG execution:

```elixir
defmodule Assistant.Orchestrator.AgentScheduler do
  @doc """
  Executes a set of agent dispatches respecting dependency ordering.
  Returns results for all agents.
  """
  def execute(dispatches, context) do
    # Build dependency graph
    graph = build_graph(dispatches)

    # Validate: no cycles
    :ok = validate_acyclic(graph)

    # Execute in topological order with parallelism
    execute_graph(graph, dispatches, context, %{})
  end

  defp execute_graph(graph, dispatches, context, completed_results) do
    # Find agents with all dependencies satisfied
    ready = find_ready_agents(graph, completed_results)

    if ready == [] and map_size(completed_results) < length(dispatches) do
      # Deadlock — should not happen if graph is acyclic
      {:error, :deadlock}
    else
      if ready == [] do
        # All done
        {:ok, completed_results}
      else
        # Execute ready agents in parallel
        new_results = execute_parallel(ready, dispatches, context, completed_results)
        all_results = Map.merge(completed_results, new_results)

        # Recurse for next wave
        execute_graph(graph, dispatches, context, all_results)
      end
    end
  end

  defp execute_parallel(agent_ids, dispatches, context, completed_results) do
    tasks = Enum.map(agent_ids, fn agent_id ->
      dispatch = Map.fetch!(dispatches, agent_id)
      dep_results = get_dependency_results(dispatch, completed_results)

      Task.Supervisor.async_nolink(
        Assistant.Orchestrator.AgentSupervisor,
        fn -> SubAgent.execute(dispatch, dep_results, context) end,
        timeout: agent_timeout(dispatch)
      )
    end)

    results = Task.yield_many(tasks, timeout: max_agent_timeout())

    Enum.zip(agent_ids, results)
    |> Enum.into(%{}, fn {id, {_task, result}} ->
      {id, normalize_result(id, result)}
    end)
  end

  defp find_ready_agents(graph, completed) do
    completed_ids = Map.keys(completed) |> MapSet.new()

    Enum.filter(graph, fn {agent_id, deps} ->
      not MapSet.member?(completed_ids, agent_id) and
        MapSet.subset?(MapSet.new(deps), completed_ids)
    end)
    |> Enum.map(fn {id, _} -> id end)
  end
end
```

### 4.3 Execution Example

```
User: "Find overdue tasks, email the report to Bob, then create a follow-up meeting"

Orchestrator dispatches:
  1. dispatch_agent(
       agent_id: "task_search",
       mission: "Search for all overdue tasks. Return a formatted list.",
      skills: ["tasks.search"]
     )

  2. dispatch_agent(
       agent_id: "email_report",
       mission: "Send an email to bob@company.com with subject 'Overdue Tasks Report'. Use the task list from the prior agent as the email body.",
      skills: ["email.send"],
       depends_on: ["task_search"]
     )

  3. dispatch_agent(
       agent_id: "create_meeting",
       mission: "Create a calendar event titled 'Task Review with Bob' for tomorrow at 2pm, 30 minutes. Invite bob@company.com.",
       skills: ["create_event"],
       depends_on: ["task_search"]
     )

Execution:
  Wave 1: task_search (no deps)
  Wave 2: email_report + create_meeting (both depend on task_search, run in parallel)
```

---

## 5. Orchestrator Loop (Revised)

### 5.1 Orchestrator Flow

The orchestrator's loop is fundamentally different from the original single-loop design. It no longer executes skills directly — it plans and delegates.

```
                     User Message
                          |
                          v
                +-------------------+
                | Load Conversation |
                | Context + Memory  |
                +-------------------+
                          |
                          v
            +---------------------------+
            |     Build LLM Request     |
            | system prompt + history   |
            | + memory + orchestrator   |
            | tools (get_skill,         |
            | dispatch_agent,           |
            | get_agent_results)        |
            +---------------------------+
                          |
                          v
            +---------------------------+
     +----->| Call OpenRouter API        |
     |      +---------------------------+
     |                |
     |                v
     |      +-------------------+
     |      | Response Type?    |
     |      +-------------------+
     |       |        |        |
     |       v        v        v
     |     text   get_skill  dispatch_agent /
     |       |       |       get_agent_results
     |       v       v              |
     |     DONE   Execute           v
     |     (send  locally     Execute agent
     |      to    (registry   coordination
     |     user)   query)     (AgentScheduler)
     |               |              |
     |               v              v
     |          Feed result    Feed results
     |          back to LLM    back to LLM
     |               |              |
     +---------------+--------------+
```

### 5.2 Orchestrator System Prompt

```
You are an AI assistant orchestrator. You coordinate sub-agents to fulfill
user requests.

Your workflow:
1. Understand the user's request
2. Call get_skill to discover relevant capabilities
3. Decompose the request into sub-tasks
4. Dispatch sub-agents via dispatch_agent (one per sub-task)
5. Collect results via get_agent_results
6. Synthesize a clear response for the user

Rules:
- You NEVER execute skills directly — always delegate to sub-agents
- For simple single-skill requests, dispatch one agent (don't over-decompose)
- For multi-step requests, identify dependencies and parallelize where possible
- Agent missions should be specific and self-contained
- Only give agents the skills they need (principle of least privilege)
- If an agent fails, decide: retry with adjusted mission, skip, or report to user

Available skill domains: {domain_list}

{user_context}
{task_summary}
{memory_context}
```

### 5.3 Simple Request Optimization

Not every request needs multi-agent decomposition. For simple single-skill requests, the orchestrator dispatches exactly one agent:

```
User: "What time is my next meeting?"

Orchestrator:
  1. get_skill(domain: "calendar")  -> discovers list_events
  2. dispatch_agent(
       agent_id: "calendar_check",
       mission: "List today's upcoming calendar events for the user.",
       skills: ["list_events"]
     )
  3. get_agent_results()
  4. "Your next meeting is 'Team Standup' at 2:00 PM."
```

This adds one layer of indirection compared to the single-loop model (orchestrator -> sub-agent -> skill vs. orchestrator -> skill). The overhead is one additional LLM call for the sub-agent. This is acceptable because:

- The sub-agent context is tiny (focused prompt + one skill schema)
- OpenRouter prompt caching benefits from repeated sub-agent patterns
- The orchestrator context stays clean for multi-turn conversations
- Consistency: the same pattern for simple and complex requests

### 5.4 Orchestrator Loop State (Revised)

```elixir
defmodule Assistant.Orchestrator.LoopState do
  @type t :: %__MODULE__{
    conversation_id: String.t(),
    user_id: String.t(),
    channel: atom(),
    turn_number: non_neg_integer(),

    # Messages for the orchestrator's context window
    messages: [map()],

    # Turn-scoped counters
    turn_orchestrator_calls: non_neg_integer(),  # LLM calls for the orchestrator
    turn_agents_dispatched: non_neg_integer(),
    turn_total_skill_calls: non_neg_integer(),   # Sum across all sub-agents

    # Agent tracking for current turn
    dispatched_agents: %{String.t() => agent_state()},

    # Conversation-scoped counters (sliding window)
    conversation_total_calls: non_neg_integer(),
    conversation_window_start: DateTime.t(),

    status: :running | :paused | :completed | :error
  }

  @type agent_state :: %{
    dispatch: map(),           # Original dispatch params
    status: :pending | :running | :completed | :failed | :timeout,
    result: String.t() | nil,
    tool_calls_used: non_neg_integer(),
    started_at: DateTime.t() | nil,
    completed_at: DateTime.t() | nil,
    duration_ms: non_neg_integer() | nil
  }
end
```

---

## 6. Sub-Agent Execution Engine

### 6.1 SubAgent Module

```elixir
defmodule Assistant.Orchestrator.SubAgent do
  @default_max_tool_calls 5
  @default_timeout_ms 30_000

  @doc """
  Execute a sub-agent mission. Returns the agent's final text response
  or an error.
  """
  def execute(dispatch, dependency_results, orchestrator_context) do
    context = build_context(dispatch, dependency_results, orchestrator_context)
    max_calls = dispatch.max_tool_calls || @default_max_tool_calls

    run_sub_loop(context.messages, context, 0, max_calls)
  end

  defp run_sub_loop(messages, context, call_count, max_calls) do
    if call_count >= max_calls do
      # Extract whatever the agent has accomplished so far
      {:ok, %{
        status: :completed,
        result: extract_last_text(messages) || "Reached tool call limit (#{max_calls}). Partial work completed.",
        tool_calls_used: call_count
      }}
    else
      case LLMClient.chat(messages, tools: context.tools, system: context.system) do
        {:ok, %{type: :text, content: text}} ->
          {:ok, %{status: :completed, result: text, tool_calls_used: call_count}}

        {:ok, %{type: :tool_calls, calls: calls}} ->
          {results, new_call_count} = execute_sub_agent_tools(calls, context, call_count)
          new_messages = messages
            ++ [%{role: "assistant", tool_calls: calls}]
            ++ Enum.map(results, fn {call, result} ->
              %{role: "tool", tool_call_id: call.id, content: result.content}
            end)
          run_sub_loop(new_messages, context, new_call_count, max_calls)

        {:error, reason} ->
          {:error, %{status: :failed, result: "LLM error: #{inspect(reason)}", tool_calls_used: call_count}}
      end
    end
  end

  defp execute_sub_agent_tools(calls, context, call_count) do
    results = Enum.map(calls, fn call ->
      case call.name do
        "use_skill" ->
          # Validate skill is in allowed list
          skill_name = call.arguments["skill"]
          if skill_name in context.allowed_skills do
            result = MetaTools.UseSkill.execute(call.arguments, context.skill_context)
            {call, elem(result, 1)}
          else
            {call, %SkillResult{
              status: :error,
              content: "Skill '#{skill_name}' is not available to this agent."
            }}
          end

        other ->
          {call, %SkillResult{status: :error, content: "Unknown tool: #{other}"}}
      end
    end)

    {results, call_count + length(calls)}
  end
end
```

### 6.2 Sub-Agent Tool Call Limit

Each sub-agent has its own tool call limit (default: 5, configurable per dispatch). This is separate from the orchestrator's conversation-level limits.

**Why a low default**: Sub-agents should be focused. A sub-agent that needs more than 5 tool calls is likely doing too much — the orchestrator should have decomposed further. The limit prevents runaway sub-agents from consuming resources.

**Configurable per dispatch**: Complex tasks (e.g., "search 3 sources and compile results") can specify `max_tool_calls: 10` or higher. The orchestrator decides based on the mission complexity.

---

## 7. Circuit Breakers and Limits (Multi-Agent)

### 7.1 Three-Level Limit Hierarchy

| Level | Scope | What It Limits | Default | Enforced By |
|-------|-------|----------------|---------|-------------|
| **1** | Per-skill | Individual skill execution timeout | 30s | Executor |
| **2** | Per sub-agent | Tool calls within one agent | 5 | SubAgent |
| **3** | Per turn (orchestrator) | Total agents dispatched + total skill calls | 8 agents, 30 skill calls | Engine |
| **4** | Per conversation | Total across sliding window | 50 calls / 5 min | Engine |

### 7.2 Orchestrator-Level Limits

```elixir
defmodule Assistant.Orchestrator.Limits do
  @max_agents_per_turn 8
  @max_total_skill_calls_per_turn 30
  @max_orchestrator_loop_iterations 6
  @conversation_max_calls 50
  @conversation_window_ms 300_000

  def check_dispatch(state, new_agent_count) do
    cond do
      state.turn_agents_dispatched + new_agent_count > @max_agents_per_turn ->
        {:tripped, :agent_limit, %{
          dispatched: state.turn_agents_dispatched,
          max: @max_agents_per_turn
        }}

      state.turn_orchestrator_calls >= @max_orchestrator_loop_iterations ->
        {:tripped, :orchestrator_loop_limit, %{
          iterations: state.turn_orchestrator_calls,
          max: @max_orchestrator_loop_iterations
        }}

      conversation_limit_exceeded?(state) ->
        {:tripped, :conversation_limit, %{}}

      true ->
        :ok
    end
  end

  def check_skill_budget(state, requested_calls) do
    if state.turn_total_skill_calls + requested_calls > @max_total_skill_calls_per_turn do
      {:tripped, :skill_budget, %{
        used: state.turn_total_skill_calls,
        max: @max_total_skill_calls_per_turn
      }}
    else
      :ok
    end
  end
end
```

### 7.3 Circuit Breaker Behavior in Multi-Agent Context

Skill-level circuit breakers work the same as before — they operate on individual skills regardless of which agent invokes them. However, the multi-agent model adds a new consideration:

**Propagation**: If a circuit breaker trips during sub-agent execution, the sub-agent receives the error and decides what to do (report failure, try alternative approach, or skip). The orchestrator then receives the sub-agent's failure report and decides at the orchestration level (retry with different agent, skip this sub-task, or report to user).

```
Skill circuit trips
    |
    v
Sub-agent receives error from use_skill
    |
    v
Sub-agent reports failure in its result
    |
    v
Orchestrator receives failure via get_agent_results
    |
    v
Orchestrator decides: retry? skip? ask user?
```

### 7.4 "Continue?" Pattern (Revised)

The "continue?" pattern still exists but is orchestrator-scoped. When the orchestrator's turn limits trip:

```
I've made progress on your request. Here's what's been done so far:

Completed:
- Searched for overdue tasks (found 3)
- Sent report to bob@company.com

Not yet started:
- Calendar event for review meeting (agent limit reached)

Would you like me to continue?
```

The orchestrator tracks which agents completed and which were not dispatched due to limits.

---

## 8. Prompt Caching Strategy

> See also: `two-tool-architecture.md` Section 6A for detailed cache breakpoint placement, `cache_control` API syntax, `RequestBuilder` module, cost model, and telemetry monitoring. This section focuses on how multi-agent orchestration affects caching.

### 8.1 The Caching Opportunity

Each sub-agent is a fresh LLM call to OpenRouter. Without caching, this means:
- Sub-agent system prompt is sent fresh each time
- Skill schemas are re-transmitted for every agent with the same skills
- The orchestrator's system prompt is re-sent every loop iteration

OpenRouter supports prompt caching for repeated prefixes. The key insight: **structure prompts so the cacheable parts come first**.

### 8.2 Cache-Friendly Prompt Structure

**Orchestrator prompt** (high cache hit rate — same across all turns):
```
[CACHEABLE PREFIX - same for every turn]
You are an AI assistant orchestrator...
Available skill domains: email, calendar, drive, tasks, hubspot, markdown, memory
Tool definitions: get_skill, dispatch_agent, get_agent_results

[VARIABLE SUFFIX - changes per turn]
User context: {name}, {channel}
Task summary: {active tasks}
Memory context: {relevant memories}
Conversation history: {messages}
```

**Sub-agent prompt** (moderate cache hit rate — same for agents using same skills):
```
[CACHEABLE PREFIX - same for all agents with this skill set]
You are a focused execution agent...
Available skills:
  - send_email: {schema}
  - search_email: {schema}

[VARIABLE SUFFIX - unique per dispatch]
Mission: {mission text}
Context: {additional context}
Dependency results: {prior agent results}
```

### 8.3 Skill Schema Caching

Since sub-agents with the same skill set share the same tool definitions, agents in the same domain benefit from OpenRouter's prompt cache. Two email-domain agents dispatched in the same conversation are very likely to hit the cache.

**Implementation**: Sort skill names alphabetically when constructing the scoped `use_skill` definition. This ensures the same skill set always produces the same tool definition text, maximizing cache hits.

```elixir
defp build_scoped_use_skill(skill_definitions) do
  # Sort alphabetically for cache-friendly ordering
  sorted = Enum.sort_by(skill_definitions, & &1.name)
  # ... build tool definition with sorted skills
end
```

---

## 9. Error Handling

### 9.1 Sub-Agent Failure Modes

| Failure | Detection | Sub-Agent Behavior | Orchestrator Response |
|---------|-----------|-------------------|----------------------|
| Skill returns error | `use_skill` returns error result | Reports error in final result | May retry with adjusted mission |
| Skill timeout | Task timeout | Reports timeout in result | May retry or skip |
| Circuit breaker open | `use_skill` returns circuit error | Reports in result, may try alternative | Informs user, may skip |
| LLM error (OpenRouter) | HTTP error | Returns `{:error, ...}` | Reports to user |
| Sub-agent timeout | `Task.yield_many` returns `nil` | N/A (killed) | Reports timeout, may retry |
| Sub-agent crashes | `Task.yield_many` returns `{:exit, ...}` | N/A (crashed) | Reports error, does not retry |
| Invalid skill name | Enum validation | Never calls use_skill | N/A (caught at tool-call level) |

### 9.2 Orchestrator Error Recovery

The orchestrator receives sub-agent results and applies error handling logic:

```elixir
defp handle_agent_results(results, state) do
  {successes, failures} = Enum.split_with(results, fn {_id, r} -> r.status == :completed end)

  case failures do
    [] ->
      # All succeeded — synthesize and respond
      {:ok, successes}

    failed ->
      # Some failed — include failure context for the orchestrator LLM
      failure_summary = Enum.map_join(failed, "\n", fn {id, r} ->
        "Agent '#{id}' failed: #{r.result}"
      end)

      # Feed back to orchestrator LLM to decide what to do
      {:partial, successes, failure_summary}
  end
end
```

When the orchestrator LLM receives partial results, it can:
1. **Report partial success**: "I completed X and Y, but couldn't do Z because..."
2. **Retry failed agent**: Dispatch a new agent with adjusted parameters
3. **Ask user**: "I couldn't send the email because Gmail is temporarily unavailable. Should I try again?"

### 9.3 Dependency Chain Failure

When a dependency fails, dependent agents cannot execute. The `AgentScheduler` handles this:

```elixir
defp handle_dependency_failure(failed_agent_id, graph, dispatches) do
  # Find all agents that transitively depend on the failed one
  affected = find_transitive_dependents(failed_agent_id, graph)

  # Mark all affected as :skipped
  Enum.map(affected, fn id ->
    {id, %{
      status: :skipped,
      result: "Skipped because dependency '#{failed_agent_id}' failed.",
      tool_calls_used: 0
    }}
  end)
end
```

The orchestrator sees which agents were skipped and why, and can decide how to proceed.

---

## 10. Elixir Implementation Patterns

### 10.1 Supervision Tree Additions

```
Assistant.Orchestrator.ConversationSupervisor (DynamicSupervisor)
|
+-- Engine (GenServer, per conversation)
    |
    +-- AgentSupervisor (Task.Supervisor, per conversation)
        |
        +-- SubAgent tasks (Task, per dispatched agent)
```

**Per-conversation AgentSupervisor**: Each conversation Engine starts its own `Task.Supervisor` for sub-agents. This provides:
- Isolation: sub-agents from different conversations cannot interfere
- Cleanup: when the conversation Engine terminates, all its sub-agents are automatically killed
- Monitoring: the Engine can track all active sub-agents via the supervisor

```elixir
defmodule Assistant.Orchestrator.Engine do
  use GenServer

  def init(opts) do
    {:ok, agent_sup} = Task.Supervisor.start_link()

    state = %LoopState{
      conversation_id: opts.conversation_id,
      user_id: opts.user_id,
      channel: opts.channel,
      agent_supervisor: agent_sup,
      # ...
    }

    {:ok, state}
  end

  def terminate(_reason, state) do
    # Kill any remaining sub-agents
    Task.Supervisor.stop(state.agent_supervisor)
    :ok
  end
end
```

### 10.2 Agent Execution via Task.Supervisor

```elixir
defp dispatch_agents(dispatches, state) do
  # Group by dependency wave
  waves = AgentScheduler.plan_waves(dispatches)

  execute_waves(waves, dispatches, state, %{})
end

defp execute_waves([], _dispatches, state, results), do: {:ok, results, state}

defp execute_waves([wave | rest], dispatches, state, accumulated_results) do
  # Spawn all agents in this wave concurrently
  tasks = Enum.map(wave, fn agent_id ->
    dispatch = Map.fetch!(dispatches, agent_id)
    dep_results = get_dependency_results(dispatch.depends_on, accumulated_results)

    task = Task.Supervisor.async_nolink(
      state.agent_supervisor,
      fn -> SubAgent.execute(dispatch, dep_results, state) end,
      timeout: agent_timeout(dispatch)
    )

    {agent_id, task}
  end)

  # Wait for all tasks in this wave
  task_refs = Enum.map(tasks, fn {_id, task} -> task end)
  yields = Task.yield_many(task_refs, timeout: max_wave_timeout())

  # Collect results
  wave_results = Enum.zip(tasks, yields)
    |> Enum.into(%{}, fn {{id, _task}, {_task_ref, result}} ->
      {id, normalize_agent_result(id, result)}
    end)

  # Check for failures and handle dependency chains
  {wave_results, skipped} = handle_wave_failures(wave_results, rest, dispatches)
  new_accumulated = Map.merge(accumulated_results, wave_results) |> Map.merge(skipped)

  # Update state counters
  new_state = update_counters(state, wave_results)

  execute_waves(rest, dispatches, new_state, new_accumulated)
end
```

### 10.3 GenServer State Flow

```
Engine receives :new_message
    |
    v
Reset turn counters
    |
    v
Build orchestrator context (conversation history + memory + tools)
    |
    v
Orchestrator LLM call #1
    |
    v
LLM returns get_skill calls -> execute locally, feed back
    |
    v
Orchestrator LLM call #2
    |
    v
LLM returns dispatch_agent calls -> collect dispatches
    |
    v
AgentScheduler.execute(dispatches, state)
    |
    +-- Wave 1: spawn parallel tasks -> collect results
    +-- Wave 2: spawn parallel tasks (with dep results) -> collect results
    +-- ...
    |
    v
Build get_agent_results response from collected results
    |
    v
Feed results back to orchestrator LLM
    |
    v
Orchestrator LLM call #3
    |
    v
LLM returns text response -> send to user
```

---

## 11. Token Budget (Revised)

### 11.1 Orchestrator Token Budget

| Component | Token Estimate | Notes |
|-----------|---------------|-------|
| Identity + instructions | ~400 | Slightly larger (orchestration rules) |
| Tool definitions (3 tools) | ~500 | get_skill + dispatch_agent + get_agent_results |
| Domain list | ~50 | Static |
| User context | ~50 | Per-conversation |
| Task summary | ~50-100 | Per-turn |
| Memory context | ~200-500 | Per-turn, FTS + structured filter retrieval |
| Conversation history | ~2,000-6,000 | Sliding window |
| Agent results (current turn) | ~200-1,000 | Summarized results from sub-agents |
| **Total** | **~3,500-8,500** | |

**Key difference**: Agent results replace raw skill execution traces in the orchestrator context. Sub-agent results are summaries ("Sent email to Bob"), not raw API responses. This keeps the orchestrator context clean.

### 11.2 Sub-Agent Token Budget

| Component | Token Estimate | Notes |
|-----------|---------------|-------|
| System prompt | ~200 | Focused role description |
| Scoped use_skill tool | ~100-400 | Only granted skill schemas |
| Mission + context | ~100-500 | From orchestrator dispatch |
| Dependency results | ~0-500 | From prior agents |
| Tool call history (within agent) | ~200-1,000 | Short-lived |
| **Total** | **~600-2,600** | |

Sub-agents are intentionally lightweight. Their context is roughly 1/3 to 1/4 of the orchestrator's, which means:
- Faster LLM inference (fewer input tokens)
- Lower cost per agent call
- More room for tool results within the agent's window

---

## 12. Message Persistence (Revised)

### 12.1 What Gets Persisted

Both orchestrator and sub-agent interactions are persisted, but at different granularity:

**Orchestrator messages** (full conversation history):
- User messages
- Orchestrator assistant messages (including tool calls to get_skill, dispatch_agent, get_agent_results)
- Tool results from get_skill and get_agent_results

**Sub-agent messages** (execution audit trail):
- Stored in `skill_executions` table (not in conversation messages)
- Each dispatch creates a parent `skill_execution` record
- Each `use_skill` call within the sub-agent creates a child execution record
- Full message trace available for debugging but NOT loaded into conversation context

### 12.2 Schema Additions

```sql
-- Extends skill_executions with agent tracking
ALTER TABLE skill_executions ADD COLUMN agent_id VARCHAR(100);
ALTER TABLE skill_executions ADD COLUMN agent_mission TEXT;
ALTER TABLE skill_executions ADD COLUMN parent_execution_id UUID REFERENCES skill_executions(id);

CREATE INDEX idx_skill_executions_agent ON skill_executions(agent_id)
  WHERE agent_id IS NOT NULL;
CREATE INDEX idx_skill_executions_parent ON skill_executions(parent_execution_id)
  WHERE parent_execution_id IS NOT NULL;
```

**Execution record hierarchy**:
```
skill_executions (parent — agent dispatch)
  agent_id: "email_sender"
  agent_mission: "Send overdue tasks report to Bob"
  skill_id: NULL (this is an agent, not a skill)
  status: "completed"
  |
  +-- skill_executions (child — individual skill call)
      parent_execution_id: {parent UUID}
      skill_id: "send_email"
      parameters: {to: ["bob@co.com"], ...}
      status: "completed"
```

### 12.3 Conversation Message Recording

The orchestrator's dispatch and results are recorded as regular conversation messages:

```elixir
# Orchestrator dispatches agents (recorded as assistant tool_call)
%{
  role: "assistant",
  tool_calls: [%{
    id: "call_abc",
    function: %{
      name: "dispatch_agent",
      arguments: ~s({"agent_id": "task_search", "mission": "...", "skills": ["tasks.search"]})
    }
  }]
}

# Agent results returned to orchestrator (recorded as tool result)
%{
  role: "tool",
  tool_call_id: "call_xyz",
  content: ~s({"agents": [{"agent_id": "task_search", "status": "completed", "result": "Found 3 overdue tasks..."}]})
}
```

This means the conversation history shows the orchestrator's planning decisions and summarized results — not the raw skill execution details from sub-agents.

---

## 13. Module Structure (Revised)

### 13.1 New Modules

| Module | Type | Purpose |
|--------|------|---------|
| `Assistant.Orchestrator.Tools.DispatchAgent` | Tool definition | dispatch_agent tool for orchestrator |
| `Assistant.Orchestrator.Tools.GetAgentResults` | Tool definition | get_agent_results tool for orchestrator |
| `Assistant.Orchestrator.SubAgent` | Execution engine | Sub-agent context building + execution loop |
| `Assistant.Orchestrator.AgentScheduler` | Coordinator | DAG-based execution with dependency resolution |

### 13.2 Modified Modules

| Module | Change |
|--------|--------|
| `Assistant.Orchestrator.Engine` | Replaces single-loop with orchestrator + sub-agent dispatch |
| `Assistant.Orchestrator.LoopState` | Adds agent tracking, revises counters |
| `Assistant.Orchestrator.Limits` | Adds agent-level and orchestrator-level limits |
| `Assistant.Orchestrator.Context` | Revised system prompt for orchestrator role |
| `Assistant.Skills.MetaTools.UseSkill` | Now only called by sub-agents, not orchestrator |

### 13.3 Unchanged Modules

| Module | Why Unchanged |
|--------|---------------|
| `Assistant.Skills.MetaTools.GetSkill` | Still used by orchestrator for discovery |
| `Assistant.Skills.Registry` | Same query interface |
| `Assistant.Skills.Executor` | Same execution path (called by UseSkill) |
| `Assistant.Skills.SchemaValidator` | Same validation logic |
| `Assistant.Skills.Skill` | Behaviour unchanged |
| All individual skill modules | No changes — transparent layer above them |

### 13.4 File Layout

```
lib/assistant/orchestrator/
  +-- engine.ex                 # MODIFIED: Orchestrator loop with agent dispatch
  +-- loop_state.ex             # MODIFIED: Agent tracking
  +-- context.ex                # MODIFIED: Orchestrator system prompt
  +-- limits.ex                 # MODIFIED: Multi-level limits
  +-- sub_agent.ex              # NEW: Sub-agent execution engine
  +-- agent_scheduler.ex        # NEW: DAG-based agent coordination
  +-- tools/                    # NEW: Orchestrator tool definitions
  |   +-- dispatch_agent.ex
  |   +-- get_agent_results.ex
  +-- llm_client.ex             # Unchanged

lib/assistant/skills/
  +-- meta_tools/
  |   +-- get_skill.ex          # Unchanged (used by orchestrator)
  |   +-- use_skill.ex          # Unchanged (used by sub-agents)
  +-- ...                       # All skill modules unchanged
```

---

## 14. Testing Strategy

### 14.1 Unit Tests

**AgentScheduler**:
- Executes independent agents in parallel
- Respects dependency ordering (serial chains)
- Handles diamond dependencies correctly
- Detects cycles and rejects
- Propagates dependency failures (skips dependents)

**SubAgent**:
- Enforces skill scoping (rejects skills not in allowed list)
- Respects max_tool_calls limit
- Returns partial result on limit trip
- Handles LLM errors gracefully
- Receives dependency results in context

**DispatchAgent tool**:
- Validates required fields (agent_id, mission, skills)
- Rejects unknown skill names
- Validates depends_on references exist

**Orchestrator Engine (revised)**:
- Dispatches agents and collects results
- Handles partial failures (some agents succeed, some fail)
- Respects turn-level limits (max agents, max total skill calls)
- "Continue?" pattern on limit trip

### 14.2 Integration Tests

- Full turn: orchestrator -> get_skill -> dispatch_agent -> sub-agent executes -> get_agent_results -> text response
- Parallel agents: two independent agents run concurrently
- Serial dependency: agent B waits for agent A
- Diamond dependency: agents B and C wait for A, agent D waits for B and C
- Sub-agent failure: one agent fails, orchestrator reports partial success
- Dependency chain failure: agent A fails, agents B and C are skipped
- Circuit breaker: skill circuit opens during sub-agent execution

### 14.3 Behavioral Tests

- Simple request: single agent dispatched and completes
- Complex request: multi-agent with dependencies
- Orchestrator decomposition quality: does the LLM create reasonable sub-tasks?
- Orchestrator synthesis quality: does the LLM produce a good user-facing response from agent results?
- Error reporting: does the orchestrator explain failures clearly to the user?

---

## 15. Integration Points

### 15.1 With Existing Two-Tool Architecture

This design **extends** the two-tool architecture rather than replacing it:
- `get_skill` is unchanged and still used by the orchestrator
- `use_skill` is unchanged and still used by sub-agents
- The Skill Registry, Executor, and all skill modules are unchanged
- JSON Schema validation works the same way

The change is in **who calls which tool**: the orchestrator calls `get_skill` + agent management tools; sub-agents call `use_skill`.

### 15.2 With Memory System

- Orchestrator receives memory context in its system prompt (unchanged)
- Sub-agents do NOT receive memory context (they get scoped missions instead)
- Tool call traces from sub-agents feed into the memory system via `skill_executions`
- Memory extraction works on sub-agent results (same as before, just different caller)
- Memory is a first-class skill domain (`:memory` with `memory.save` and `memory.search` skills). The orchestrator may dispatch a memory-focused sub-agent for explicit recall requests. See `two-tool-architecture.md` Section 14.3 for full memory skill definitions.
- Memory search uses PostgreSQL hybrid retrieval (FTS + pgvector similarity + structured filters). See `system-architecture.md` Revision 6 for schema.

### 15.3 With Task Management

- Task skills are dispatched to sub-agents like any other skill
- The orchestrator may dispatch a "task_agent" with `["tasks.search", "tasks.update"]` for task-related requests
- No changes to task skill implementations

### 15.4 With Voice Pipeline

- Voice channel handling is unchanged (modality conversion at adapter boundary)
- The orchestrator processes voice input the same way as text input
- Sub-agents are always text-based (they never handle audio directly)

### 15.5 With Circuit Breakers

- Skill-level circuit breakers work identically (checked by UseSkill)
- New orchestrator-level limits provide additional protection (max agents, max total skill calls)
- Sub-agent failures propagate through the dependency graph

---

## 16. Open Questions

1. **Sub-agent model selection**: Should all sub-agents use the same LLM model as the orchestrator? Simpler tasks could use a faster/cheaper model (e.g., Claude Haiku for single-skill lookups, Sonnet for complex multi-step agents). OpenRouter makes multi-model trivial.

2. **Agent result summarization**: Should sub-agents be instructed to produce brief summaries, or should the system summarize their results before passing to the orchestrator? Current design: sub-agents produce their own summaries. Alternative: a post-processing step that truncates/summarizes long results.

3. **Conversation-aware sub-agents**: Should sub-agents receive conversation history excerpts for context-dependent tasks? e.g., "The user mentioned Bob's email is bob@company.com earlier in the conversation." Current design: no — the orchestrator passes relevant context via the `context` field. This keeps sub-agent contexts minimal.

4. **Sub-agent retry logic**: Should the orchestrator automatically retry failed agents, or always report to the LLM for a decision? Current design: report to LLM. Automatic retry risks loops. But a single automatic retry for transient errors (timeouts) could be valuable.

5. **Streaming sub-agent results**: Should results stream back to the orchestrator as sub-agents complete (enabling progressive synthesis), or batch until all complete? Current design: batch per wave. Streaming would improve perceived latency for the user but adds complexity.

---

## 17. Design Decision Summary

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Architecture | Orchestrator + sub-agents (multi-agent) | Clean separation of planning and execution; orchestrator context stays clean |
| Orchestrator tools | get_skill + dispatch_agent + get_agent_results | Discovery + delegation + collection — orchestrator never executes skills |
| Sub-agent tools | Scoped use_skill only | Principle of least privilege; enum restriction on skill names |
| Dependency model | DAG with `depends_on` field | Supports serial, parallel, and diamond patterns |
| Execution | Task.Supervisor per conversation | BEAM-native concurrency with fault isolation |
| Sub-agent context | Minimal (mission + skill schemas + dep results) | Fast inference, low cost, focused execution |
| Error handling | Propagate to orchestrator LLM for decision | Orchestrator has full context for error recovery |
| Prompt caching | Cache-friendly prefix ordering | Alphabetical skill sorting, static prefix sections |
| Default sub-agent limit | 5 tool calls | Forces focused agents; configurable per dispatch |
| Persistence | Orchestrator in conversation messages, sub-agents in skill_executions | Clean conversation history; full audit trail available |

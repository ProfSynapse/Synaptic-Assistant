# Implementation Plan: Task-Master Orchestrator

> Created: 2026-03-06
> Status: PROPOSED

## Summary

Shift Synaptic Assistant from an agent-centric orchestration model to a task-centric control plane:

- the orchestrator becomes the only authority that can mutate tasks
- the orchestrator no longer does non-task domain work directly
- every meaningful unit of work is represented in the task system
- every subagent run is attached to a task
- subagents keep dynamic tool leasing, but tools are granted per run and may be expanded only through orchestrator approval
- subagents never mutate task state directly; they report results and the orchestrator updates tasks

This plan compares the current architecture to that target state, file by file, and lays out a migration path that reuses the existing Engine, LoopRunner, SubAgent, and task infrastructure instead of replacing them.

---

## Specialist Perspectives

### 📋 Preparation Phase
**Effort**: Medium

#### Current State (Confirmed)

- The orchestrator tool surface is still purely meta-agent oriented in `lib/assistant/orchestrator/context.ex`:
  - `cancel_agent`
  - `dispatch_agent`
  - `get_agent_results`
  - `get_skill`
  - `query_subagent`
  - `send_agent_update`
- The orchestrator prompt in `priv/config/prompts/orchestrator.yaml` explicitly says:
  - "You NEVER execute skills yourself"
  - "You ALWAYS delegate via dispatch_agent"
  This directly conflicts with the desired "orchestrator owns task state" model.
- Subagents already support dynamic capability leasing:
  - `dispatch_agent` grants an initial `skills` list
  - `send_agent_update` can add more skills later
  - `SubAgent` enforces only the currently granted skills
- Task CRUD already exists as normal skill handlers:
  - `lib/assistant/skills/tasks/create.ex`
  - `lib/assistant/skills/tasks/get.ex`
  - `lib/assistant/skills/tasks/search.ex`
  - `lib/assistant/skills/tasks/update.ex`
  - `lib/assistant/skills/tasks/delete.ex`
- The task domain already has richer internal capabilities than the skill surface currently exposes:
  - dependencies in `lib/assistant/task_manager/queries.ex`
  - comments in `lib/assistant/task_manager/queries.ex`
  - history in `lib/assistant/task_manager/queries.ex`
- Execution state and task state are still separate:
  - subagent runs are tracked via `execution_logs`
  - tasks do not own or reference agent runs directly
  - `execution_logs` have no `task_id`
- The context system already injects active task summaries into orchestrator prompts through `lib/assistant/memory/context_builder.ex`, but tasks are treated as context, not as the primary control primitive.

#### Product Direction (from request)

- The orchestrator is the project manager and task master.
- The task system is the orchestrator's main durable control plane.
- The orchestrator should create, update, reprioritize, block, complete, cancel, and decompose tasks continuously.
- The orchestrator should not perform domain work directly outside task management.
- Subagents are dynamic workers that receive a task-scoped capability lease.
- Subagents may request more tools or context when blocked.
- Only the orchestrator mutates tasks.

#### Core Product Rules

1. The orchestrator is the only task writer.
2. The orchestrator is the only agent manager.
3. Every dispatched subagent must be associated with a task.
4. Subagents may use only the tools currently granted by the orchestrator.
5. Tool expansion is explicit through orchestrator-mediated escalation.
6. Subagent results are proposals, evidence, or artifacts; they are not durable state until the orchestrator writes task updates.

#### Main Gaps vs Target

- The orchestrator cannot currently call task CRUD directly.
- The orchestrator prompt teaches the wrong behavior.
- The orchestrator's purpose is not explicitly defined as "task master / project manager"; it is still defined as a generic delegation hub.
- Task mutation currently happens only if a subagent is granted `tasks.*`.
- There is no required `task_ref` on dispatches.
- There is no durable task-to-agent-run link.
- The task skill surface is missing orchestration-grade operations like dependency management and task comments/notes.

---

### 🏗️ Architecture Phase
**Effort**: High

#### Target Behavior

```text
User request
  -> orchestrator creates/updates task graph
  -> orchestrator selects runnable tasks
  -> orchestrator dispatches subagent(s) for those tasks with minimal tool leases
  -> subagent reports findings / artifacts / blockers
  -> orchestrator updates task status, notes, dependencies, follow-up tasks
  -> orchestrator dispatches next wave
```

#### Core Architectural Decision

Keep the current Engine/SubAgent execution architecture, but invert ownership:

- today: agents are primary, tasks are optional tools
- target: tasks are primary, agents are temporary execution slots attached to tasks

This means:

- `dispatch_agent` becomes task-aware
- task updates move into the orchestrator tool surface
- subagents retain dynamic tool leasing
- subagents lose direct task mutation authority

#### Prompt-Level Purpose Change

The orchestrator prompt must be updated explicitly, not just incidentally.

Today the prompt defines the orchestrator primarily as:
- a delegator
- a multi-agent planner
- a tool router

The target prompt must define the orchestrator primarily as:
- the task master
- the project manager
- the sole owner of task state
- the authority that decides when to create tasks, split tasks, dispatch workers, expand worker capabilities, and close or block work

The prompt should state these rules directly:

1. Your primary job is to manage the task graph.
2. Represent meaningful work in tasks before or while delegating it.
3. You are the only component that may mutate task state.
4. Subagents work on tasks but do not update tasks.
5. If you need domain work done, dispatch a subagent for a task.
6. Use subagent results to update tasks, create follow-up tasks, or change dependencies.

#### File-by-File Current vs Target

| File | Current Behavior | Target Behavior |
|------|------------------|-----------------|
| `priv/config/prompts/orchestrator.yaml` | Teaches "always delegate" and "never execute skills yourself." | Teach "manage tasks directly, delegate domain work through task-bound subagents, and write all task state yourself." |
| `lib/assistant/orchestrator_system_prompt.ex` | Supports user-configured prompt fragments, but those fragments append onto the current delegator-first system prompt. | Continue supporting custom prompt fragments, but ensure they layer on top of an explicit task-master base prompt rather than the old generic orchestration identity. |
| `lib/assistant/orchestrator/context.ex` | Registers only meta-agent tools. | Add orchestrator-only task tools and keep agent-control tools. |
| `lib/assistant/orchestrator/loop_runner.ex` | Routes only meta-agent tools. | Route task CRUD/task orchestration tools plus existing agent-control tools. |
| `lib/assistant/orchestrator/engine.ex` | Owns agent state, but not task lifecycle. | Own task progression rules around each dispatch/result cycle. |
| `lib/assistant/orchestrator/tools/dispatch_agent.ex` | Validates mission/skills and creates an `execution_log`, but has no `task_ref`. | Require `task_ref`, record task linkage, and treat dispatch as work on behalf of a task. |
| `lib/assistant/orchestrator/sub_agent.ex` | Executes any granted skills, including task skills if granted. | Continue dynamic leasing, but never grant task-write capability from orchestrator mode. |
| `lib/assistant/orchestrator/tools/send_agent_update.ex` | Resumes paused agents and may add more skills/context. | Keep this behavior; it becomes the sanctioned capability-escalation path for a task-bound worker. |
| `lib/assistant/orchestrator/tools/get_skill.ex` | Skill discovery for all domains. | Keep, but teach the orchestrator to use it only for subagent leasing, not for direct self-execution outside tasks. |
| `lib/assistant/skills/tasks/create.ex` | Normal skill handler, callable only through normal skill execution. | Reused behind orchestrator-only task tools or refactored into shared task tool modules callable by orchestrator directly. |
| `lib/assistant/skills/tasks/update.ex` | Normal skill handler used by any caller with `tasks.update`. | Keep for non-orchestrator contexts if desired, but orchestrator mode must prevent subagents from receiving it. |
| `lib/assistant/skills/tasks/delete.ex` | Normal task archiving skill. | Same as above. |
| `lib/assistant/task_manager/queries.ex` | Rich DB layer for CRUD, dependencies, comments, history. | Becomes the main persistence layer for orchestrator task control and new orchestration-grade task tools. |
| `lib/assistant/memory/context_builder.ex` | Tasks are summarized as passive prompt context. | Continue summary injection, but source task information from the orchestrator-managed task graph and emphasize runnable/blocked work. |
| `lib/assistant/schemas/execution_log.ex` | Tracks agent execution without `task_id`. | Add direct task linkage or introduce a dedicated task-run mapping. |
| `lib/assistant/transcripts.ex` | Can infer related tasks from conversation/task history. | Expand to show agent runs attached to tasks as first-class traceability. |
| `docs/architecture/task-management-design.md` | Treats tasks as a first-class skill domain. | Update to reflect tasks as the orchestrator control plane, not just another skill family. |

#### Recommended Authority Model

**Orchestrator**
- May use task tools directly.
- May dispatch, inspect, update, and cancel subagents.
- May grant or expand subagent capability leases.
- May not do domain work directly outside the task control surface.

**Subagents**
- Receive only the currently granted tools.
- May request more tools, context, or mission clarification.
- May not mutate tasks directly in orchestrator mode.
- Return structured outputs to the orchestrator.

#### Target Tool Split

**Orchestrator tools**
- `tasks.create`
- `tasks.get`
- `tasks.search`
- `tasks.update`
- `tasks.delete`
- `tasks.add_dependency`
- `tasks.remove_dependency`
- `tasks.add_comment`
- `dispatch_agent`
- `get_agent_results`
- `query_subagent`
- `send_agent_update`
- `cancel_agent`
- `get_skill`

**Subagent tools**
- Only the tools granted for that run by the orchestrator
- Never `tasks.*` in orchestrator mode
- External write tools allowed only if product explicitly permits them for that task type

#### Recommended Data Model Change

The current `execution_logs` table is too detached from tasks for a task-master orchestrator. One of these should become the standard:

1. Add `task_id` to `execution_logs`
2. Add a dedicated `task_runs` table pointing to both `tasks` and `execution_logs`

Recommendation: prefer `task_runs` if we expect retries, superseding, multi-agent waves per task, or richer lifecycle reporting. Prefer `task_id` on `execution_logs` only if we want the smallest schema change.

#### Task and Agent Lifecycle Separation

**Task states**
- `todo`
- `in_progress`
- `blocked`
- `done`
- `cancelled`

**Agent states**
- `pending`
- `running`
- `awaiting_orchestrator`
- `completed`
- `failed`
- `timeout`
- `cancelled`
- `skipped`

The orchestrator translates agent outcomes into task updates. No subagent state should directly mutate task status.

---

### 💻 Code Phase
**Effort**: High

#### Files to Create

| File | Purpose |
|------|---------|
| `lib/assistant/orchestrator/tools/task_create.ex` | Orchestrator-only wrapper for task creation |
| `lib/assistant/orchestrator/tools/task_get.ex` | Orchestrator-only wrapper for task lookup |
| `lib/assistant/orchestrator/tools/task_search.ex` | Orchestrator-only wrapper for task search |
| `lib/assistant/orchestrator/tools/task_update.ex` | Orchestrator-only wrapper for task mutation |
| `lib/assistant/orchestrator/tools/task_delete.ex` | Orchestrator-only wrapper for task archive/cancel flows |
| `lib/assistant/orchestrator/tools/task_add_dependency.ex` | Orchestrator-only dependency tool |
| `lib/assistant/orchestrator/tools/task_remove_dependency.ex` | Orchestrator-only dependency removal tool |
| `lib/assistant/orchestrator/tools/task_add_comment.ex` | Orchestrator-only task note/comment tool |
| `lib/assistant/orchestrator/task_policy.ex` | Shared policy for orchestrator-mode task authority and subagent capability restrictions |
| `test/assistant/orchestrator/task_master_flow_test.exs` | Integration coverage for task-driven orchestration behavior |
| `test/assistant/orchestrator/tools/task_tools_test.exs` | Unit coverage for orchestrator task tool wrappers |

#### Files to Modify

| File | Change |
|------|--------|
| `priv/config/prompts/orchestrator.yaml` | Rewrite prompt around task ownership and task-first delegation |
| `lib/assistant/orchestrator_system_prompt.ex` | Verify custom prompt fragments remain appended safely to the new task-master base prompt |
| `lib/assistant/orchestrator/context.ex` | Register orchestrator task tools in addition to agent-control tools |
| `lib/assistant/orchestrator/loop_runner.ex` | Route and format task tool calls |
| `lib/assistant/orchestrator/engine.ex` | Track task-bound dispatches and update task state based on agent results |
| `lib/assistant/orchestrator/tools/dispatch_agent.ex` | Require `task_ref`; persist task linkage on dispatch |
| `lib/assistant/orchestrator/sub_agent.ex` | Enforce task-tool denial in orchestrator mode while preserving dynamic leasing for other tools |
| `lib/assistant/orchestrator/tools/send_agent_update.ex` | Preserve dynamic lease expansion; optionally annotate added tools against task run history |
| `lib/assistant/schemas/execution_log.ex` | Add task linkage or prepare for `task_runs` association |
| `lib/assistant/task_manager/queries.ex` | Expose or tighten orchestration-grade operations for dependencies/comments and task status transitions |
| `lib/assistant/memory/context_builder.ex` | Prioritize task graph summary over passive active-task listing |
| `lib/assistant/transcripts.ex` | Show task-linked agent runs in conversation/task trace views |
| `docs/architecture/task-management-design.md` | Align architecture docs with the new control-plane role of tasks |
| `test/assistant/orchestrator/loop_runner_test.exs` | Add task tool routing coverage |
| `test/assistant/orchestrator/engine_test.exs` | Add task-bound dispatch and task state progression coverage |
| `test/assistant/orchestrator/sub_agent_test.exs` | Add "cannot mutate tasks directly in orchestrator mode" coverage |
| `test/integration/skills/tasks_test.exs` | Clarify which task paths remain skill-level versus orchestrator-level |

#### Implementation Sequence

**Phase 1: Teach the Orchestrator the Right Job**
1. Rewrite `priv/config/prompts/orchestrator.yaml` so the orchestrator's stated purpose is explicitly "task master / project manager", not generic delegator.
2. Add orchestrator-native task tools to `context.ex` and `loop_runner.ex`.
3. Confirm `lib/assistant/orchestrator_system_prompt.ex` still appends user customization onto the new base identity cleanly.
4. Keep existing subagent control tools unchanged.

**Phase 2: Make Dispatch Task-Aware**
1. Add `task_ref` to `dispatch_agent`.
2. Persist task linkage to the execution record.
3. Reject task-less dispatches in orchestrator mode.

**Phase 3: Remove Task Mutation from Workers**
1. Introduce orchestrator-mode policy that blocks granting `tasks.*` to subagents.
2. Preserve dynamic leasing for non-task tools.
3. Keep `send_agent_update` as the escalation path for more tools/context.

**Phase 4: Expand the Task Surface to Match PM Duties**
1. Add orchestrator task tools for dependencies and comments.
2. Add conventions for task notes derived from subagent outputs.
3. Add explicit task state transition helpers if needed.

**Phase 5: Tighten Traceability**
1. Add durable task-to-run linkage.
2. Surface that linkage in transcripts/debug views.
3. Add tests for reruns, cancellations, blocked tasks, and follow-up task creation.

---

### 🧪 Test Phase
**Effort**: Medium-High

#### Test Scenarios

| Scenario | Type | Priority |
|----------|------|----------|
| Orchestrator can create/update/search tasks directly | Integration | P0 |
| Orchestrator dispatch requires `task_ref` | Unit | P0 |
| Subagent cannot receive `tasks.*` in orchestrator mode | Unit | P0 |
| Subagent can request more non-task tools via `send_agent_update` | Integration | P0 |
| Agent completion updates task state only through orchestrator logic | Integration | P0 |
| Agent failure/blocker maps to `blocked` task handling | Integration | P0 |
| Task dependency/comment tools work for orchestrator | Unit | P1 |
| Task-linked execution history is queryable in transcripts/debug views | Integration | P1 |
| Existing non-orchestrator task skills still work where intentionally supported | Integration | P1 |
| Prompt regression: orchestrator no longer plans to mutate external systems directly | Integration | P1 |
| Prompt regression: orchestrator identifies its role as task master/project manager and uses tasks as the durable control plane | Integration | P1 |

#### Coverage Targets

- CRITICAL path (task authority boundaries, dispatch/task linkage, blocked task handling): 90%+
- HIGH path (prompt behavior, orchestration loop, traceability): 85%+
- STANDARD path (transcript/reporting surfaces): 80%+

#### Regression Risks to Guard

- Breaking existing prompt/tool-call assumptions in `loop_runner.ex`
- Accidentally disabling valid non-orchestrator uses of `tasks.*`
- Over-coupling subagent policy to a single mode when `single_loop` still exists
- Confusing agent terminal state with task terminal state

---

### 🛡️ Security and Control Concerns
**Effort**: Medium

- Capability expansion must remain explicit and auditable.
- The orchestrator must not silently regain direct non-task domain execution powers.
- Task mutation authority should live in one place to avoid split-brain state.
- If external write tools remain available anywhere in the product, orchestrator mode must define a clear allow/deny policy so subagents do not become an uncontrolled write path.

---

## Recommended First Cut

If we want the minimum viable migration, do this first:

1. Rewrite the orchestrator prompt.
2. Add orchestrator-native task CRUD/search tools.
3. Add `task_ref` to `dispatch_agent`.
4. Prevent granting `tasks.*` to subagents in orchestrator mode.
5. Link agent runs to tasks.

That is enough to flip the architecture from "tasks as optional skills" to "tasks as the orchestrator's source of truth" without rewriting the runtime.

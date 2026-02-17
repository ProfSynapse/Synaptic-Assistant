# Design Review: Skills-First AI Assistant

> Reviewed: 2026-02-17
> Reviewers: architect-reviewer, backend-reviewer (test-reviewer findings unavailable due to delivery issue)
> Documents reviewed: 7 (plan + 5 architecture docs + Elixir best practices)
> Overall verdict: **STRONG architecture, implementable as designed, with targeted security and design improvements needed**

---

## Executive Summary

Two specialist reviewers independently assessed the full architecture across security, design coherence, OTP patterns, Elixir implementation feasibility, and interface contracts. Both reached high confidence that the architecture is sound and implementation-ready.

**One critical finding** requires resolution before CODE phase: agent-to-agent prompt injection (SEC1). Several high-priority items should be addressed during ARCHITECT phase refinement. The remaining items can be incorporated during implementation.

---

## Critical Findings (Must Address Before CODE)

### SEC1: Agent-to-Agent Prompt Injection [CRITICAL]
**Source**: Architect reviewer

Sub-agent results flow unsanitized into downstream agent contexts via the DAG dependency chain. If Agent A returns malicious content (either from a compromised API response or adversarial user input that survived earlier filtering), Agent B's context is poisoned.

**Current state**: Architecture mentions "scoped context" but defines no output sanitization between agents.

**Recommendation**:
- Add output sanitization/validation between agent results before injection into subsequent agent contexts
- Define a "result schema" that sub-agents must conform to
- Consider stripping or escaping any content that resembles tool calls or system instructions
- Document the sanitization boundary in `sub-agent-orchestration.md`

---

## High Priority Findings (Address During ARCHITECT Phase)

### SEC2: CLI Command Injection via Parsing [HIGH]
**Source**: Architect reviewer

The CLI Extractor uses regex to parse ```cmd blocks. Malformed or adversarial command syntax could exploit flag parsing. While commands route to Elixir handlers (no shell execution), carefully crafted commands could abuse flag interpretation.

**Recommendation**:
- Define a strict command grammar (not just regex)
- Validate tokenized output against a whitelist of known commands before dispatch
- Reject unknown commands at the router level
- Backend reviewer adds: use a proper shell-style tokenizer with quote handling (~50 lines), not just OptionParser

### SEC3: No Per-User Rate Limiting [HIGH]
**Source**: Architect reviewer

Circuit breakers protect at per-skill, per-agent, per-turn, and per-conversation levels. But no per-user limit exists. A malicious user could open multiple conversations to bypass per-conversation limits.

**Recommendation**: Add per-user rate limiting as a 5th circuit breaker level.

### Orchestrator Engine Complexity [HIGH]
**Source**: Backend reviewer

The `engine.ex` GenServer handles conversation state, LLM calls, tool parsing, sub-agent dispatch, DAG coordination, circuit breakers, rate limiting, message persistence, and response routing. High risk of becoming a god object.

**Recommendation**: Extract a `LoopRunner` module encapsulating the agent loop as pure functions that receive and return state. The GenServer handles only state management and dispatch. This makes the loop testable without starting a GenServer.

```elixir
defmodule Assistant.Orchestrator.LoopRunner do
  def run(messages, state) -> {:done, text, state} | {:paused, summary, state} | {:error, reason, state}
end
```

### Hybrid Access Lacks Explicit Contract [HIGH]
**Source**: Architect reviewer, Backend reviewer (corroborating)

The orchestrator can directly invoke read-only skills but must delegate mutating skills. This classification lives nowhere in the skill definition — the YAML frontmatter (name + description) has no `access` field. The boundary is enforced by naming convention only.

**Recommendation**: Add an explicit `access: read | write` field to skill YAML frontmatter, or encode the convention as a hard validation rule in the skill loader (e.g., skills matching `*.search|*.get|*.list|*.read` are auto-classified as read-only).

### Sub-Agent Latency for Simple Queries [HIGH]
**Source**: Backend reviewer

Simple query like "What time is my next meeting?" requires 5 LLM calls minimum (3 orchestrator + 2 sub-agent). At ~1-2s per call = 5-10s latency.

**Recommendation**: Implement orchestrator direct read-only skill access as a Phase 1 priority (not deferred). Reduces simple queries to 2-3 LLM calls.

---

## Medium Priority Findings (Incorporate During CODE Phase)

### Design Coherence Issues

| ID | Finding | Recommendation |
|----|---------|----------------|
| C1 | Document supersession ambiguous — two-tool-architecture.md has mixed current/superseded sections | Add explicit CURRENT/SUPERSEDED markers per section, or fold valid sections into canonical docs |
| C3 | Workflow failure semantics undefined — what happens when step 3 of 5 fails? | Define failure semantics (atomic vs partial completion) in markdown-skill-system.md |
| S1 | Notification system spans 5 concerns (trigger, route, format, deliver, log) | Decompose into separate modules |
| S2 | Bidirectional task-memory coupling | Introduce PubSub for task->memory flow; task context injection as read-only query |
| S3 | Compaction ownership unclear in C4 diagram | Assign to specific container |

### Interface Contract Gaps

| ID | Finding | Recommendation |
|----|---------|----------------|
| I1 | dispatch_agent return value undefined | Define return schemas for all 3 orchestrator tools |
| I2 | get_agent_results polling semantics unclear (blocking? polling? timeout?) | Define contract explicitly |
| I3 | CLI pipeline error types undefined between extractor -> router -> handler stages | Define explicit error types per stage |

### Security Items

| ID | Severity | Finding | Recommendation |
|----|----------|---------|----------------|
| SEC4 | MEDIUM | File replace integrity — no post-REPLACE verification | Use atomic file operations (write to temp + rename) |
| SEC5 | MEDIUM | FTS query injection — user input into tsquery | Use `plainto_tsquery` or `websearch_to_tsquery` for user-provided input |
| SEC6 | LOW | Webhook verification per channel not specified | Add verification method table per channel to system-architecture.md |

### Implementation Concerns

| ID | Severity | Finding | Recommendation |
|----|----------|---------|----------------|
| BE1 | MEDIUM | CLI parser edge cases (quoted values, unicode, empty strings) | Build thin custom tokenizer with proper quote handling |
| BE2 | MEDIUM | Conversation GenServer lifecycle underspecified (idle timeout, state recovery, race conditions) | Use Registry for lookup; on recovery load summary + recent N messages |
| BE3 | LOW-MED | Circuit breaker DB write pressure if persisting every state change | Persist only on state transitions (closed->open, etc.); use ETS for hot state |

---

## Database Schema Gaps

Three gaps identified by backend reviewer — all should be resolved in the initial migration, not retrofitted:

1. **Entity graph tables** — `memory_entity`, `memory_entity_relation`, `memory_entity_mention` referenced in project structure but never defined. Either define during ARCHITECT phase or remove from project structure.

2. **Conversation summary fields** — `summary`, `summary_version`, `summary_model` mentioned for continuous compaction but missing from conversations schema.

3. **Sub-agent execution fields** — `agent_id`, `agent_mission`, `parent_execution_id` should be in the base `skill_executions` migration (nullable), not added as ALTER statements later.

---

## Missing Dependencies

Add to mix.exs during project scaffold:

| Package | Purpose | Why Missing |
|---------|---------|-------------|
| `yaml_elixir` | Parse YAML frontmatter in skill markdown files | `earmark` parses markdown, not YAML |
| `file_system` | FileSystem watcher for skill hot-reload | Referenced in architecture but not in deps list |
| `nimble_parsec` (optional) | Robust CLI tokenizer if regex proves insufficient | Recommended by backend reviewer |

---

## Agreements Between Reviewers

Both reviewers independently confirmed:
- Architecture is **sound and implementation-ready**
- OTP supervision tree is **well-designed** (DynamicSupervisor, Task.Supervisor, one_for_one)
- Behaviour-first design is **excellent** (enables Mox, provider swapping, compile-time contracts)
- CLI-first skill paradigm is **innovative and well-suited** to LLM interaction
- PostgreSQL FTS + tags approach is **pragmatic** (defer pgvector, additive later)
- File versioning invariant (never delete) is **well-thought-out**
- Phased implementation sequence is **realistic**
- Dependency choices are **solid** (req, oban, goth, quantum, fuse)

---

## Items Needing Resolution Before CODE

Prioritized checklist for ARCHITECT phase refinement:

- [x] **SEC1**: ~~Design agent-to-agent output sanitization~~ → **RESOLVED**: Three-layer defense: (1) `confirm` field on skills, (2) Sentinel LLM (context-isolated, returns boolean — sees only original request + mission + proposed action), (3) if sentinel returns `false`, surface to user. Data/instruction boundary delimiters on external content. Orchestrator logs all decisions.
- [x] **SEC3**: ~~Add per-user rate limiting~~ → **RESOLVED**: Deferred. Single-user system; per-conversation limits sufficient.
- [x] **Hybrid access**: ~~Add access field to skill YAML~~ → **RESOLVED**: `confirm: true/false` field on skills. Read-only skills (`*.search`, `*.get`, `*.list`, `*.read`) default `confirm: false`; mutating skills default `confirm: true`. Overridable per skill.
- [ ] **LoopRunner extraction**: Document the split in engine architecture
- [x] **Entity graph schema**: ~~Define or defer~~ → **RESOLVED**: Define now, include in Phase 1.
- [ ] **Conversation summary fields**: Add to base schema
- [ ] **Sub-agent execution fields**: Include in base migration (+ sentinel_decision, sentinel_reason, user_confirmed columns)
- [ ] **Tool return schemas**: Define for get_skill, dispatch_agent, get_agent_results
- [x] **Workflow failure semantics**: ~~Document in markdown-skill-system.md~~ → **RESOLVED**: Workflows are agentic. Sub-agent gets workflow.md as mission + scoped skills, executes adaptively. Failure semantics = sub-agent failure semantics (retry, adapt, escalate to orchestrator).
- [x] **CLI tokenizer approach**: ~~Decide robustness level~~ → **RESOLVED**: Basic quote handling. LLMs produce clean syntax.
- [x] **Direct read-only access**: ~~Confirm Phase 1~~ → **RESOLVED**: Yes, Phase 1.

---

## Limitations

| Gap | Impact | Recommendation |
|-----|--------|----------------|
| Test-reviewer findings unavailable (message delivery failure) | Missing dedicated testability assessment, coverage gap analysis, and security testing scenarios | Testing perspective partially covered by architect (security tests) and backend (Mox boundaries, smoke tests). Recommend a focused test strategy review before TEST phase begins. |

---

## Next Steps

1. User reviews this document and the updated plan
2. Resolve the 11 pre-CODE items above during ARCHITECT phase
3. Proceed with `/PACT:orchestrate` after plan approval

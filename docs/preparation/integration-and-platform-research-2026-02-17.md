# Integration & Platform Research (2026-02-17)

## Scope
This document resolves the open preparation-phase research items in `docs/plans/skills-first-assistant-plan.md` and provides implementation recommendations for the Elixir-first architecture.

Integration policy (project-wide):
- **Prefer direct HTTP integrations via `Req` behind behaviours**.
- Treat third-party SDK/wrapper libraries as optional accelerators, not core architecture dependencies.

---

## 1) Elixir ecosystem audit

### Telegex
- Package: `telegex` (`1.8.0`, `1.9.0-rc.0` available), active release history in 2024.
- Positioning: Telegram bot framework with generated client/types.
- Recommendation: **Req-first Telegram adapter**. `telegex` can be used selectively for convenience, but keep core transport under direct HTTP control.

### whatsapp_elixir
- Package: `whatsapp_elixir` (`0.1.8`, Sep 2025), active 2025 release cadence.
- Positioning: Wrapper over WhatsApp Cloud API using `req`.
- Recommendation: **Use initially for message send helpers only**; for webhook parsing and newer endpoints, keep a direct HTTP client path ready.

### google_api_drive
- Package: `google_api_drive` (`0.32.0`, Nov 2024), official Google-generated client package.
- Recommendation: Prefer **Req + `goth`** for primary Drive integration path. Keep `google_api_drive` as optional reference/fallback if codegen coverage saves substantial effort.

### goth
- Package: `goth` (`1.4.5`, Dec 2024), widely used and high adoption.
- Recommendation: **Use for service account + DWD token minting**.

Decision: **Req-first integration strategy** with behaviour boundaries; use external wrappers only where they materially reduce effort and don’t constrain API coverage.

---

## 2) OpenRouter API research

### Tool-calling format
- OpenRouter normalizes to OpenAI-style chat schema.
- Supports `tools`, `tool_choice`, and provider transformation when providers differ.
- Recommendation: keep existing orchestrator contract (`get_skill`, `dispatch_agent`, `get_agent_results`) and rely on normalized OpenRouter tool schema.

### Streaming protocol
- SSE supported via `stream: true`.
- Stream may include comment frames (ignore safely).
- Final chunk includes usage data for streamed calls.
- Mid-stream error format is explicit (`finish_reason: "error"`).

Runtime policy for this project:
- **Default to non-streaming LLM responses** for simpler control flow, easier retries, and cleaner tool-call/state handling.
- Enable streaming only as an explicit opt-in for UX-sensitive surfaces where partial-token rendering materially improves experience.
- Keep usage/cost accounting on complete responses as the primary path; treat streamed responses as a specialized mode.

### Model fallback/routing
- If model/provider fails, OpenRouter can route/fallback based on provider availability.
- Recommendation: configure provider preferences where compliance/latency requires; allow fallback by default.

### Prompt caching
- Cache metrics exposed in usage (`prompt_tokens_details.cached_tokens`, `cache_write_tokens`).
- Anthropic/Gemini support `cache_control` breakpoint semantics in content; provider-specific TTL/cost behavior applies.
- Recommendation: place cache breakpoints on large stable context blocks (policy text, index chunks, skills text).

Decision: **OpenRouter feature set fits orchestrator + sub-agent architecture directly.**

---

## 3) Google OAuth2: service account + DWD

Validated flow:
1. Create service account in GCP.
2. Enable domain-wide delegation and copy service account client ID.
3. In Workspace Admin Console: Security → API Controls → Manage Domain Wide Delegation → add client ID + required scopes.
4. Use `goth` to mint delegated user tokens (`sub`/impersonation user) per request context.

Key requirement: super-admin action is mandatory for DWD authorization.

Decision: **Proceed with service account + DWD as primary auth strategy** for Drive/Gmail/Calendar organizational automation.

---

## 4) WhatsApp Business API strategy

Meta platform notes:
- Cloud API supports messaging + webhooks and Graph API transport.
- Webhooks are core to receiving inbound messages/status.
- Throughput/rate limits and template rules are explicit and must be respected.

Implementation recommendation:
- Keep `whatsapp_elixir` for outgoing message convenience.
- Build first-party webhook verification + event normalization in `channel_adapters/whatsapp`.
- Keep direct `Req` Graph API client for unsupported features (templates/management edge cases).

Decision: **Hybrid package + raw HTTP strategy**.

---

## 5) HubSpot API strategy

Observations:
- `hubspotex` is old (`0.0.6`, 2017) and low-activity.
- HubSpot official docs show broad modern API surface and recent updates.

Recommendation:
- Do **not** depend on `hubspotex` for core production integration.
- Build typed `Req` wrappers around required HubSpot endpoints with explicit schemas + retry/rate-limit middleware.

Decision: **Raw HTTP client (Req) is the default path for HubSpot.**

---

## 6) ElevenLabs API research

Key capability signals:
- Fast TTS models exist (`Flash v2.5`) and low-latency options are documented.
- API docs include TTS + STT capability families and model selection guidance.

Recommended architecture:
- Use ElevenLabs for TTS only (per current decisions).
- Add voice profile abstraction (`voice_id`, model, speaking rate/style controls).
- Implement streaming audio path where available for lower time-to-first-audio.
- Cache repeated prompt templates and static utterances at app layer.

Latency guidance:
- Budget toward sub-second TTFB for short utterances where possible; continuously benchmark by model/region.

Decision: **ElevenLabs remains preferred TTS provider.**

---

## 7) OpenRouter STT input format

Research outcome:
- OpenRouter docs clearly expose chat/responses/embeddings endpoints in current public references.
- Audio transcription docs path appears to exist under API reference routing (`/docs/api/api-reference/audio/create-transcription`) but automated extraction did not reliably return schema details.

Practical decision for implementation:
- Treat OpenRouter STT payload as **pending schema lock** until endpoint spec is machine-verified in CI (OpenAPI or live sandbox call).
- Keep STT behind `voice.transcribe` adapter interface so provider payload shape remains encapsulated.

Interim implementation plan:
1. Add provider contract test that validates a real transcription request/response shape.
2. Store canonical payload example in repo once validated.
3. If OpenRouter STT endpoint remains unstable/undocumented, temporarily switch STT to a directly documented provider endpoint and keep OpenRouter as preferred target.

Decision: **Proceed with OpenRouter STT as target, but gate rollout on schema contract test.**

---

## 8) MCP protocol (2025-11-25 spec) and necessity

Findings:
- MCP is an interoperability standard for connecting AI clients to external tools/data.
- Current spec uses version negotiation and stable protocol framing.

Assessment for this project:
- Current architecture is internal, CLI-first, and orchestrator-controlled with explicit skill registry and adapters.
- No immediate need for third-party MCP client/server interoperability for MVP.

Decision:
- **MCP is not required for MVP.**
- Adopt MCP-inspired concepts (capability discovery, typed tool schemas, transport-agnostic boundaries).
- Revisit MCP server/client compatibility when external tool ecosystem interoperability becomes a product requirement.

---

## 9) Railway deployment research (Elixir/Phoenix)

Validated from Phoenix deployment docs:
- Production setup should use runtime env secrets (`config/runtime.exs`).
- Standard production flow: deps/compile, asset build, migrations, server boot.
- Phoenix docs reference Railway community guide for Mix release deployments.

Recommended deployment profile:
- Build as Mix release.
- Run migrations on deploy/release command.
- Use managed Postgres (Railway provisioning) + `DATABASE_URL`.
- Add health endpoint (`/healthz`) used by platform checks.
- Configure rolling deploy-safe shutdown + startup probe windows.

Decision: **Railway is viable for MVP deployment with Phoenix release + Postgres.**

---

## 10) Elixir best practices baseline

Ecosystem maturity confirmation:
- `phoenix`, `ecto_sql`, `postgrex`, `req`, `oban` all show strong and recent release activity.

Baseline conventions for this codebase:
- OTP: isolate long-lived state in GenServers; keep business logic in pure modules/contexts.
- Boundaries: channel adapters, integration clients, and skill executors as separate behaviours.
- Reliability: Oban for retries/backoff/dead-letter handling; circuit breakers per architecture docs.
- Testing: ExUnit + integration tests for external clients (Mox/stubs for provider APIs) + contract tests for skill CLI parsing.
- Observability: structured logging + telemetry spans on orchestrator/sub-agent/tool execution.

Decision: **Proceed with standard Phoenix/OTP architecture patterns; no nonstandard framework required.**

---

## 11) Channel adapters: add Slack as first-class interface

Goal:
- Treat chat interfaces as pluggable adapters behind a shared `ChannelAdapter` behaviour.

Adapter model:
- Existing/active: Google Chat, Telegram, WhatsApp, Voice.
- Add now: **Slack**.
- Future-ready: any chat surface can plug in if it can map to normalized inbound/outbound message contracts.

Recommended implementation shape:
- Create `channel_adapters/slack` with the same callback contract as other channels.
- Handle Slack signature verification and event/webhook normalization at adapter boundary.
- Map Slack thread/channel/user identifiers into canonical conversation identity used by orchestrator.
- Keep outbound sender separated so message formatting differences stay adapter-local.

Decision:
- **Adopt channel adapters as a stable extension point and include Slack in baseline adapter set.**

---

## 12) Extensibility contract: add apps/skills with env-var credentials

Goal:
- Make new app integrations easy to layer in without re-architecting core orchestration.

Contract:
- New integrations should require:
	1. Environment variables for credentials/config.
	2. A thin `Req` adapter behind a behaviour.
	3. Skill modules (or markdown skill definitions) that call that adapter.
- No orchestrator/protocol redesign for each new app.

Environment variable conventions:
- Credential: `<APP>_API_KEY` (or provider-appropriate token name).
- Base URL (if needed): `<APP>_BASE_URL`.
- Optional model/profile defaults: `<APP>_MODEL`, `<APP>_VOICE_ID`, etc.
- Feature flag for staged rollout: `<APP>_ENABLED=true|false`.

Onboarding checklist for a new app:
1. Add env vars in runtime/deploy platform.
2. Add `Assistant.Integrations.<App>` behaviour + `Req` client implementation.
3. Add one read-only skill first (`<domain>.search`/`<domain>.get`) to validate contracts.
4. Add mutating skills with Sentinel + confirmation policy.
5. Add integration contract tests (auth, retries, error mapping, rate limits).

Decision:
- **Environment-driven onboarding is a first-class architectural requirement**: credentials in env vars, adapter behind behaviour, then skills.

---

## Final recommendation summary
- Keep current architecture direction (Elixir + PostgreSQL + OpenRouter + ElevenLabs + unified `files.*` domain).
- Treat MCP as optional/future interoperability layer, **not a required foundation**.
- Use a **Req-first integration model** behind behaviours; keep third-party SDKs optional and replaceable.
- Prefer adapter-wrapped HTTP clients for less mature integrations (`HubSpot`, potentially advanced WhatsApp features).
- Add contract tests for OpenRouter STT before production rollout.
- Standardize chat surfaces as pluggable channel adapters and include Slack in initial supported interfaces.
- Keep integration onboarding environment-driven: new apps should be mostly env vars + one adapter + skills.

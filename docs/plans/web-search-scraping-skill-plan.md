# Implementation Plan: Web Search and Scraping Skills

> Created: 2026-03-04
> Status: PENDING APPROVAL
> Direction: Add a first-class `web` skill domain where search is powered by OpenRouter/OpenAI web search with citations, while fetch/extract/save remain deterministic local skills.

## Summary

The best path for Synaptic Assistant is a hybrid, skills-first design:

1. `web.search` should use OpenRouter/OpenAI web search first, and the assistant must preserve returned citations from `annotations` / `url_citation`.
2. `web.fetch` and `web.extract` should be deterministic internal skills built on `Req`, with strict robots/compliance, SSRF protection, content-type limits, and per-host rate limiting.
3. Fetched content should be optionally saveable into the existing folder/file system, either through a `save_to` argument or by composing with the existing `files.write` flow.
4. JavaScript-heavy pages should use an optional remote scraping fallback instead of making browser automation the default path.

This recommendation is a repo-specific inference based on:

- the existing markdown + handler skill runtime
- the existing `Req`-based integration pattern
- the existing OpenRouter client already being present in the repo
- the OpenAI client currently being chat-completions oriented, even though OpenAI recommends Responses for new work
- the need for reusable, testable, provider-independent skills

## Why This Is the Best Fit Here

### Current repo constraints

- Skills are already first-class runtime objects via `Assistant.Skills.Registry`, `Assistant.Skills.Executor`, and markdown definitions under `priv/skills/`.
- Integration clients are thin Elixir modules behind a registry, which matches a provider-behaviour approach.
- `Req` is already the project-standard HTTP client.
- `Assistant.Integrations.OpenAI` is built around Chat Completions today, while OpenAI recommends the Responses API for new tool-enabled work.
- `Assistant.Integrations.OpenRouter` currently supports chat completions and tool calling, but not yet the `plugins` request surface or citation parsing needed for OpenRouter web search.
- Runtime HTML parsing is not currently present; `:floki` is test-only in `mix.exs`.

### Recommendation

Build explicit `web.*` skills first, but let `web.search` call model-native web search through OpenRouter or OpenAI. That gives the assistant:

- native citations from the provider
- a reusable skill contract for the orchestrator/sub-agents
- a separate deterministic fetch/save layer for when the assistant must inspect or persist a specific page

Recommended search order:

- OpenRouter web plugin first for models already routed through OpenRouter
- Direct OpenAI web search second once a Responses client is added
- Dedicated search API only as a fallback if vendor search quality, pricing, or rate limits become an issue

## Options Evaluated

| Option | Strengths | Weaknesses | Recommendation |
|--------|-----------|------------|----------------|
| Model-native web search + local fetch/extract/save | Native citations; lowest time-to-value; matches your desired UX; still allows deterministic follow-up fetches | Requires client work for OpenRouter/OpenAI web-search request/response shapes | Recommended core |
| Dedicated search API + internal fetch/extract | Deterministic; skill-friendly; reusable in workflows; provider-independent | More moving parts up front; gives up native citation path from model providers | Fallback option |
| Full browser automation by default | Best coverage for JS-heavy pages | Operationally heavy; higher latency/cost; much harder to secure and test | Avoid as default |
| Remote scrape/crawl service fallback | Covers JS-heavy pages without local browser infra | Extra vendor + cost; still needs local policy checks | Recommended fallback |

## External Research Findings

### 1. OpenAI web search supports citations, but the best long-term integration is the Responses API

OpenAI documents web search in both the Responses API and Chat Completions. For Chat Completions it uses specialized search models and returns `annotations`; for Responses it exposes the `web_search` tool and OpenAI recommends Responses for new work. That means OpenAI is viable for cited search, but the repo would need a Responses-oriented integration to do it cleanly.

### 2. OpenRouter web search already standardizes citations in an OpenAI-style annotation shape

OpenRouter documents the `web` plugin and standardizes results as `annotations` with `url_citation`. It can also force `"engine": "native"` for providers that support native search. This is a strong fit for this repo because OpenRouter is already wired in and can become the first implementation of `web.search`.

### 3. A separate fetch capability is still required even if search is model-native

Even with native search and citations, the assistant still needs deterministic page retrieval for follow-up tasks such as:

- pulling the full text from one cited URL
- extracting article text or structured sections
- saving the page snapshot into the assistant's folder system
- re-reading the page later without paying for another web-search call

### 4. Scraping should default to fetch + extract, not browser automation

Firecrawl's official docs position the product around scrape, crawl, map, extract, and search. That is strong evidence for using a remote service only where needed, especially for JavaScript-heavy or anti-bot pages. It should be a fallback, not the primary path.

### 5. Robots compliance needs to be explicit

RFC 9309 standardizes robots.txt behavior, including user-agent matching and group precedence. The assistant should treat robots as a first-class gate before fetch or crawl and should log when a URL is rejected by policy.

## Proposed Architecture

### Skill surface

Phase 1 should add three skills:

| Skill | Purpose | Typical caller |
|-------|---------|----------------|
| `web.search` | Run OpenRouter/OpenAI web search and return answer text plus normalized citations | Orchestrator or sub-agent |
| `web.fetch` | Fetch one URL safely and return metadata + raw cleaned content, with optional save-to-folder behavior | Sub-agent |
| `web.extract` | Extract readable text or structured fields from a fetched page | Sub-agent |

Phase 2 can add:

| Skill | Purpose |
|-------|---------|
| `web.crawl` | Controlled multi-page crawl with host/page caps |
| `web.research` | Convenience meta-skill that searches, fetches top results, deduplicates, and returns a source-backed brief |

### Integration boundary

Add a new `web` integration family behind behaviours:

| Behaviour | Default implementation | Role |
|-----------|------------------------|------|
| `SearchProvider` | OpenRouter web plugin first, OpenAI web search second | Produce cited search results |
| `Fetcher` | Internal `Req` client | Retrieve pages safely |
| `Extractor` | Internal HTML-to-text pipeline | Produce readable content |
| `ScrapeProvider` | Firecrawl fallback | Handle JS-heavy or complex pages |

This keeps the system aligned with the existing `Assistant.Integrations.Registry` pattern and lets the assistant switch providers later without changing the skill interface.

### Result contract

Each `web.*` skill should return structured metadata in both human-readable and machine-readable forms.

Minimum metadata:

- source URL
- canonical URL if different
- page title
- HTTP status
- content type
- fetched at timestamp
- provider name
- extraction method (`static`, `scrape_fallback`, `cached`)

`web.search` should also include:

- normalized citations extracted from `annotations`
- source URL + title for each citation
- provider name (`openrouter` or `openai`)
- raw provider payload in metadata for debugging when needed

## Recommended Provider Strategy

### Core recommendation

- `web.search`: OpenRouter web plugin first
- `web.search` alternative: direct OpenAI web search
- `web.fetch`: internal `Req` client
- `web.extract`: internal HTML extraction pipeline
- JS-heavy fallback: Firecrawl

### Why this split is better than one vendor for everything

- It gives you native citations directly from OpenRouter/OpenAI.
- It keeps ordinary page fetches inside the app, where timeout, robots, host policy, and caching are fully under our control.
- It uses a remote scraping vendor only where plain HTTP fetch is not enough.
- It still gives the assistant a reusable fetch/save capability that is independent of the search provider.

### Search-provider policy

Recommended policy:

- If the active LLM path is OpenRouter, use OpenRouter `plugins: [{"id": "web"}]` and parse `annotations`.
- If the active LLM path is direct OpenAI, prefer Responses `tools: [{type: "web_search"}]`.
- When using OpenRouter with OpenAI-capable models and citations matter, consider forcing `"engine": "native"` so results come from provider-native search.

## Citation Requirements

`web.search` is not complete unless citations are normalized and preserved.

Required behavior:

- capture inline-citation metadata from provider annotations
- return a normalized `citations` list in skill metadata
- keep citation URL, title, and text span offsets when available
- render citations as clickable links in any user-facing UI

This is directly supported by OpenAI's `annotations` / `url_citation` response shape and OpenRouter's standardized annotation schema.

## Security and Compliance Requirements

### Network safety

The fetch layer should reject:

- `localhost`
- private IP ranges
- link-local ranges
- metadata endpoints
- non-HTTP schemes

This is an engineering inference, not a direct external-source requirement, but it is mandatory if the assistant can fetch arbitrary URLs.

### Robots and crawl policy

Before `web.fetch` or `web.crawl` runs:

1. resolve and normalize the URL
2. fetch and cache `robots.txt` per host
3. evaluate the configured bot user-agent against RFC 9309 group rules
4. reject disallowed paths with a clear tool result

### Response limits

Enforce:

- max redirects
- max response bytes
- content-type allowlist
- per-host timeout
- per-host concurrency
- per-host rate limiting

### Data handling

- Store minimal cached page content with TTL, not indefinite raw copies by default
- Preserve provenance metadata for every extracted artifact
- Treat paywalled or authenticated pages as out of scope unless a future integration explicitly supports them
- If content is saved to the folder system, stamp the file with source URL, fetch timestamp, and citation provenance in frontmatter or sidecar metadata

## Execution Plan

### Phase 0: Design and contracts

1. Define the `web` domain skill names, parameters, and result shapes.
2. Decide the default search provider order: OpenRouter first, OpenAI second.
3. Decide whether extracted content is cached in Postgres, ETS, or both.
4. Decide whether persistence uses `web.fetch --save_to` or composes through the existing file skills.

### Phase 1: Minimal public-web capability

1. Add `web.search`
2. Add `web.fetch`
3. Add `web.extract`
4. Add policy enforcement: SSRF, robots, content-type, limits
5. Add citation normalization from OpenRouter/OpenAI annotations
6. Add optional save-to-folder behavior using the existing file system

Deliverable:
The assistant can search with citations, fetch a cited page, and save the retrieved text into the assistant folder system.

### Phase 2: Better extraction and failure handling

1. Add HTML readability cleanup
2. Add caching by canonical URL + ETag/Last-Modified where available
3. Add JS-heavy fallback via remote scrape provider
4. Add deduplication of repeated URLs across search results

Deliverable:
The assistant handles common modern websites without making browser automation the default path.

### Phase 3: Higher-level research workflows

1. Add `web.crawl` with hard host/page caps
2. Add `web.research` meta-skill
3. Add synthesis prompts that require source-backed claims
4. Add analytics for domains, latency, failures, and cache hit rate

Deliverable:
The assistant can perform bounded research tasks and produce source-backed briefs.

## Proposed File/Module Shape

### New markdown skill definitions

- `priv/skills/web/SKILL.md`
- `priv/skills/web/search.md`
- `priv/skills/web/fetch.md`
- `priv/skills/web/extract.md`
- later: `priv/skills/web/crawl.md`
- later: `priv/skills/web/research.md`

### New Elixir modules

- `lib/assistant/integrations/web/search_provider.ex`
- `lib/assistant/integrations/web/openrouter_search.ex`
- `lib/assistant/integrations/web/openai_search.ex`
- `lib/assistant/integrations/web/fetcher.ex`
- `lib/assistant/integrations/web/http_fetcher.ex`
- `lib/assistant/integrations/web/extractor.ex`
- `lib/assistant/integrations/web/html_extractor.ex`
- `lib/assistant/integrations/web/robots.ex`
- `lib/assistant/integrations/web/url_policy.ex`
- `lib/assistant/integrations/web/cache.ex`
- optional later: `lib/assistant/integrations/web/firecrawl.ex`

### New skill handlers

- `lib/assistant/skills/web/search.ex`
- `lib/assistant/skills/web/fetch.ex`
- `lib/assistant/skills/web/extract.ex`
- later: `lib/assistant/skills/web/crawl.ex`
- later: `lib/assistant/skills/web/research.ex`

### Existing files likely to change

- `lib/assistant/integrations/registry.ex`
- `lib/assistant/skills/context.ex`
- `config/runtime.exs`
- `config/test.exs`
- `mix.exs`

## Dependency Notes

### Required

- No new HTTP client should be added; use `Req`

### Recommended Elixir packages

- `Req`
  Use this for all HTTP fetches and provider calls. It is already in the repo and matches project guidance.
- `Floki`
  Good default runtime HTML parser for text extraction and selector-based cleanup.
- `html5ever`
  Good companion to `Floki` when you want a more robust parser. Floki documents this integration directly.
- `robots`
  A maintained Hex package whose package description is simply "A parser for robots.txt."

### Packages I would not make the default here

- `readability`
  It is relevant, but Hex shows it depends on `httpoison`. Since this repo explicitly prefers `Req` and avoids `HTTPoison`, I would not adopt it as-is.
- `fast_html`
  It is fast, but it needs extra native build tooling and carries LGPL-2.1-only licensing. I would only use it if we hit a real parsing-performance bottleneck.

### Likely needed

- a runtime HTML parser/extractor library, or
- a deliberate choice to keep extraction minimal internally and rely more heavily on the remote scrape fallback

Because the repo currently has `:floki` only in `:test`, this should be an explicit decision instead of an accidental mid-implementation dependency change.

## Testing Plan

### Unit tests

- robots policy parsing and precedence
- URL normalization and SSRF rejection
- search result normalization
- HTML extraction edge cases
- cache key/canonical URL behavior

### Integration tests

- `web.search` against mocked provider responses
- `web.fetch` against `Bypass`
- redirect handling
- content-type rejection
- over-size body rejection
- robots disallow rejection
- citation extraction/normalization from OpenRouter/OpenAI responses
- save-to-folder behavior for fetched content
- fallback to remote scrape provider on configured conditions

### Skill tests

- markdown definitions load correctly
- result formatting is compact enough for LLM context
- failures return structured, non-crashing `Result` payloads

## Success Criteria

- The assistant can answer "search the web for X" with source URLs and snippets.
- The assistant can answer "search the web for X" with preserved clickable citations from the provider response.
- The assistant can inspect a returned URL without bypassing host safety or robots policy.
- The same URL is not repeatedly refetched inside a short window.
- The assistant can save a fetched page into its folder system with provenance metadata.
- JS-heavy pages fail over cleanly when fallback scraping is enabled.
- The skill outputs remain useful as standalone tools inside orchestrator and sub-agent flows.

## What Not To Do

- Do not make browser automation the default transport.
- Do not skip robots or SSRF controls just because the caller is an internal agent.
- Do not bake provider-specific fields into the public skill contract.
- Do not drop provider annotations on the floor; citations are a product requirement.

## Open Questions

- Should extracted page content be persisted for later semantic retrieval, or kept as short-lived cache only?
- Should `web.fetch` save directly, or should the orchestrator compose `web.fetch` with `files.write`?
- Should `web.search` default to OpenRouter everywhere first, or select OpenAI directly when the user is not on OpenRouter?
- Should source-backed research summaries be emitted by a dedicated meta-skill or composed ad hoc by the orchestrator?

## Sources

- [OpenAI: Why we built the Responses API](https://developers.openai.com/blog/responses-api)
- [OpenAI Docs: Web search guide](https://platform.openai.com/docs/guides/tools-web-search)
- [OpenAI Docs: Responses vs. Chat Completions](https://platform.openai.com/docs/guides/responses-vs-chat-completions)
- [OpenRouter Docs: Web Search Plugin](https://openrouter.ai/docs/features/web-search)
- [Firecrawl Docs](https://docs.firecrawl.dev/introduction)
- [RFC 9309: Robots Exclusion Protocol](https://www.rfc-editor.org/rfc/rfc9309)
- [Hex: Req](https://hex.pm/packages/req)
- [Hex: Floki](https://hex.pm/packages/floki)
- [Hex: html5ever](https://hex.pm/packages/html5ever)
- [Hex: robots](https://hex.pm/packages/robots)
- [Hex: readability](https://hex.pm/packages/readability)
- [Hex: fast_html](https://hex.pm/packages/fast_html)

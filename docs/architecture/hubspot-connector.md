# HubSpot CRM Connector -- Architecture

## Executive Summary

This document defines the architecture for adding HubSpot CRM skills to the Synaptic
Assistant. The connector covers three CRM object types (Contacts, Companies, Deals)
with six operations each (create, get, update, delete, search, list\_recent) for a
total of 18 skills. The design follows existing project conventions established by
the email and calendar skill families.

---

## System Context

```
User (chat) ──> Orchestrator ──> SubAgent ──> Skill Handler
                                                   │
                                                   ▼
                                          HubSpot.Client
                                                   │
                                                   ▼
                                        HubSpot CRM v3 API
                                    (api.hubapi.com/crm/v3/)
```

**Authentication**: Single Bearer token (HubSpot Private App token) resolved via
`IntegrationSettings.get(:hubspot_api_key)`. Not per-user OAuth -- one org-wide key.

**Existing touchpoints**:
- `IntegrationSettings.Registry`: already has `"hubspot"` group with `:hubspot_api_key`
  and `:hubspot_enabled` keys.
- `ConnectionValidator`: already validates HubSpot via `HubSpot.Client.health_check/1`.
- `Skills.Context`: already has `optional(:hubspot) => module()` in the integrations type.
- `Integrations.Registry`: does NOT yet include `:hubspot` in `default_integrations/0`.

---

## Module Hierarchy

```
lib/assistant/
├── integrations/hubspot/
│   └── client.ex                      # HTTP client (expand existing)
├── skills/hubspot/
│   ├── helpers.ex                     # HubSpot-domain helpers
│   ├── contacts/
│   │   ├── create.ex                  # hubspot.create_contact
│   │   ├── get.ex                     # hubspot.get_contact
│   │   ├── update.ex                  # hubspot.update_contact
│   │   ├── delete.ex                  # hubspot.delete_contact
│   │   ├── search.ex                  # hubspot.search_contacts
│   │   └── list_recent.ex            # hubspot.list_recent_contacts
│   ├── companies/
│   │   ├── create.ex                  # hubspot.create_company
│   │   ├── get.ex                     # hubspot.get_company
│   │   ├── update.ex                  # hubspot.update_company
│   │   ├── delete.ex                  # hubspot.delete_company
│   │   ├── search.ex                  # hubspot.search_companies
│   │   └── list_recent.ex            # hubspot.list_recent_companies
│   └── deals/
│       ├── create.ex                  # hubspot.create_deal
│       ├── get.ex                     # hubspot.get_deal
│       ├── update.ex                  # hubspot.update_deal
│       ├── delete.ex                  # hubspot.delete_deal
│       ├── search.ex                  # hubspot.search_deals
│       └── list_recent.ex            # hubspot.list_recent_deals
priv/skills/hubspot/
├── SKILL.md                           # Domain description
├── create_contact.md
├── get_contact.md
├── update_contact.md
├── delete_contact.md
├── search_contacts.md
├── list_recent_contacts.md
├── create_company.md
├── get_company.md
├── update_company.md
├── delete_company.md
├── search_companies.md
├── list_recent_companies.md
├── create_deal.md
├── get_deal.md
├── update_deal.md
├── delete_deal.md
├── search_deals.md
└── list_recent_deals.md
```

---

## Component Architecture

### 1. HubSpot.Client (Expand Existing)

**File**: `lib/assistant/integrations/hubspot/client.ex`

The existing client has only `health_check/1`. Expand it with CRM CRUD methods.
All methods accept `api_key` as the first parameter (same pattern as existing).

#### API Method Signatures

```elixir
defmodule Assistant.Integrations.HubSpot.Client do
  # Existing
  @spec health_check(String.t()) :: {:ok, :healthy} | {:error, term()}

  # -- Contacts --
  @spec create_contact(String.t(), map()) :: {:ok, map()} | {:error, term()}
  @spec get_contact(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @spec update_contact(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  @spec delete_contact(String.t(), String.t()) :: :ok | {:error, term()}
  @spec search_contacts(String.t(), String.t(), String.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  @spec list_recent_contacts(String.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}

  # -- Companies --
  @spec create_company(String.t(), map()) :: {:ok, map()} | {:error, term()}
  @spec get_company(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @spec update_company(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  @spec delete_company(String.t(), String.t()) :: :ok | {:error, term()}
  @spec search_companies(String.t(), String.t(), String.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  @spec list_recent_companies(String.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}

  # -- Deals --
  @spec create_deal(String.t(), map()) :: {:ok, map()} | {:error, term()}
  @spec get_deal(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @spec update_deal(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  @spec delete_deal(String.t(), String.t()) :: :ok | {:error, term()}
  @spec search_deals(String.t(), String.t(), String.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  @spec list_recent_deals(String.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
end
```

#### Internal Design

The client uses `Req` directly (no HubSpot SDK). All methods follow this pattern:

```elixir
def create_contact(api_key, properties) do
  url = "#{base_url()}/crm/v3/objects/contacts"

  case Req.post(url,
         json: %{properties: properties},
         headers: auth_headers(api_key),
         receive_timeout: 10_000,
         retry: false
       ) do
    {:ok, %Req.Response{status: 201, body: body}} ->
      {:ok, normalize_object(body)}

    {:ok, %Req.Response{status: status, body: body}} ->
      {:error, {:api_error, status, extract_error_message(body)}}

    {:error, reason} ->
      {:error, {:request_failed, reason}}
  end
end
```

**Private helpers in client** (keep in client.ex, not exported):

| Helper | Purpose |
|--------|---------|
| `auth_headers/1` | Returns `[{"authorization", "Bearer #{api_key}"}]` |
| `base_url/0` | Reads `:hubspot_api_base_url` config (already exists) |
| `extract_error_message/1` | Extracts `"message"` from error body (already exists) |
| `normalize_object/1` | Extracts `%{id, properties, created_at, updated_at}` from API response |
| `build_search_body/3` | Builds search API request body from `(property, operator, value)` |

**HubSpot CRM v3 API endpoints used**:

| Operation | Method | Path |
|-----------|--------|------|
| Create | POST | `/crm/v3/objects/{objectType}` |
| Get | GET | `/crm/v3/objects/{objectType}/{id}` |
| Update | PATCH | `/crm/v3/objects/{objectType}/{id}` |
| Delete (archive) | DELETE | `/crm/v3/objects/{objectType}/{id}` |
| Search | POST | `/crm/v3/objects/{objectType}/search` |
| List recent | GET | `/crm/v3/objects/{objectType}?limit=N&properties=...` |

Since the three CRM types share the same REST pattern, the client should use a
generic internal function:

```elixir
defp crm_create(api_key, object_type, properties) do ...end
defp crm_get(api_key, object_type, id, properties_list) do ...end
defp crm_update(api_key, object_type, id, properties) do ...end
defp crm_delete(api_key, object_type, id) do ...end
defp crm_search(api_key, object_type, property, operator, value, limit, properties_list) do ...end
defp crm_list(api_key, object_type, limit, properties_list) do ...end
```

The public methods then delegate:

```elixir
def create_contact(api_key, properties), do: crm_create(api_key, "contacts", properties)
def create_company(api_key, properties), do: crm_create(api_key, "companies", properties)
def create_deal(api_key, properties),    do: crm_create(api_key, "deals", properties)
```

Each public method specifies the default `properties_list` to request from the API
for read operations (search, get, list\_recent).

**Default properties per object**:

| Object | Default Properties |
|--------|-------------------|
| Contacts | `email`, `firstname`, `lastname`, `phone`, `company` |
| Companies | `name`, `domain`, `website`, `industry`, `description` |
| Deals | `dealname`, `amount`, `closedate`, `dealstage`, `pipeline`, `description` |

#### Search Semantics

The search skill for each object type accepts two parameters:
- `query` (required) -- the search term
- `search_by` (optional) -- which property to search

**Search-by options per object**:

| Object | search_by options | Default |
|--------|------------------|---------|
| Contacts | `email`, `name` | `email` |
| Companies | `name`, `domain` | `name` |
| Deals | `name`, `stage` | `name` |

For name-based searches, use `CONTAINS_TOKEN` operator. For exact fields (email,
domain), use `EQ`. For stage searches, use `EQ` on `dealstage`.

---

### 2. HubSpot.Helpers

**File**: `lib/assistant/skills/hubspot/helpers.ex`

```elixir
defmodule Assistant.Skills.HubSpot.Helpers do
  @moduledoc false

  alias Assistant.Skills.Helpers, as: SkillsHelpers

  @default_limit 10
  @max_limit 50

  def parse_limit(value), do: SkillsHelpers.parse_limit(value, @default_limit, @max_limit)

  @doc "Build a maybe_put map from optional flags."
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, _key, ""), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc "Format a CRM object into a human-readable text block."
  def format_object(object, fields) do
    fields
    |> Enum.map(fn {label, key} ->
      value = get_in(object, [:properties, key]) || get_in(object, ["properties", key])
      if value, do: "#{label}: #{value}", else: nil
    end)
    |> Enum.reject(&is_nil/1)
    |> then(fn lines ->
      id = object[:id] || object["id"]
      ["ID: #{id}" | lines]
    end)
    |> Enum.join("\n")
  end

  @doc "Format a list of CRM objects separated by dividers."
  def format_object_list(objects, fields, object_type_label) do
    case objects do
      [] ->
        "No #{object_type_label} found."

      list ->
        formatted = Enum.map_join(list, "\n\n---\n\n", &format_object(&1, fields))
        "Found #{length(list)} #{object_type_label}:\n\n#{formatted}"
    end
  end
end
```

**Design decision**: `maybe_put/3` is duplicated from `Calendar.Helpers` intentionally.
The calendar version is calendar-domain; this is hubspot-domain. Cross-domain sharing
of `maybe_put` would require promoting it to `Skills.Helpers`, which is a separate
refactoring choice. Keeping it local follows the existing domain-helper pattern.

---

### 3. Skill Handlers

Every handler follows this template (mirroring `Email.Send`, `Calendar.Create`):

```elixir
defmodule Assistant.Skills.HubSpot.Contacts.Create do
  @behaviour Assistant.Skills.Handler

  alias Assistant.Skills.HubSpot.Helpers
  alias Assistant.Skills.Result

  @impl true
  def execute(flags, context) do
    case Map.get(context.integrations, :hubspot) do
      nil ->
        {:ok, %Result{status: :error, content: "HubSpot integration not configured."}}

      hubspot ->
        case resolve_api_key() do
          nil ->
            {:ok, %Result{status: :error, content: "HubSpot API key not found. Configure it in Settings."}}

          api_key ->
            do_execute(hubspot, api_key, flags)
        end
    end
  end

  defp resolve_api_key do
    Assistant.IntegrationSettings.get(:hubspot_api_key)
  end

  defp do_execute(hubspot, api_key, flags) do
    # validate flags, build properties, call hubspot.create_contact(api_key, properties)
    # return %Result{...}
  end
end
```

**Key differences from Google skills**:
- No `google_token` check -- HubSpot uses a global API key, not per-user OAuth.
- API key resolved via `IntegrationSettings.get(:hubspot_api_key)` directly in
  the handler (not threaded through context metadata).
- The `hubspot` module in `context.integrations` provides the client module
  (`Assistant.Integrations.HubSpot.Client`), enabling test injection.

**Why resolve API key in handler, not in context builder?**

The context builder (`sub_agent.ex:build_skill_context`) currently only resolves
Google tokens lazily (checking if dispatched skills need Google). Adding HubSpot
key resolution there would couple the context builder to HubSpot knowledge.
Instead, each HubSpot handler resolves its own key via `IntegrationSettings.get/1`.
This is simple, explicit, and matches how the ConnectionValidator already resolves it.

---

### 4. Skill Definitions (Markdown)

Each skill gets a markdown definition in `priv/skills/hubspot/`.

**Domain definition** (`priv/skills/hubspot/SKILL.md`):

```yaml
---
domain: hubspot
description: "HubSpot CRM skills for managing contacts, companies, and deals."
---
```

**Individual skill definition pattern** (example: `create_contact.md`):

```yaml
---
name: "hubspot.create_contact"
description: "Create a new contact in HubSpot CRM."
handler: "Assistant.Skills.HubSpot.Contacts.Create"
confirm: true
tags:
  - hubspot
  - crm
  - contacts
  - write
parameters:
  - name: "email"
    type: "string"
    required: true
    description: "Contact email address"
  - name: "first_name"
    type: "string"
    required: false
    description: "Contact first name"
  - name: "last_name"
    type: "string"
    required: false
    description: "Contact last name"
  - name: "phone"
    type: "string"
    required: false
    description: "Phone number"
  - name: "company"
    type: "string"
    required: false
    description: "Company name"
  - name: "properties"
    type: "string"
    required: false
    description: "Additional properties as JSON (e.g. '{\"jobtitle\": \"CTO\"}')"
---
```

**Naming convention**: `confirm: true` on all mutating skills (create, update, delete).

#### Complete Skill Inventory

| Skill Name | Handler Module | Confirm | Tags |
|------------|---------------|---------|------|
| `hubspot.create_contact` | `HubSpot.Contacts.Create` | yes | hubspot, crm, contacts, write |
| `hubspot.get_contact` | `HubSpot.Contacts.Get` | no | hubspot, crm, contacts, read |
| `hubspot.update_contact` | `HubSpot.Contacts.Update` | yes | hubspot, crm, contacts, write |
| `hubspot.delete_contact` | `HubSpot.Contacts.Delete` | yes | hubspot, crm, contacts, write, delete |
| `hubspot.search_contacts` | `HubSpot.Contacts.Search` | no | hubspot, crm, contacts, read, search |
| `hubspot.list_recent_contacts` | `HubSpot.Contacts.ListRecent` | no | hubspot, crm, contacts, read, list |
| `hubspot.create_company` | `HubSpot.Companies.Create` | yes | hubspot, crm, companies, write |
| `hubspot.get_company` | `HubSpot.Companies.Get` | no | hubspot, crm, companies, read |
| `hubspot.update_company` | `HubSpot.Companies.Update` | yes | hubspot, crm, companies, write |
| `hubspot.delete_company` | `HubSpot.Companies.Delete` | yes | hubspot, crm, companies, write, delete |
| `hubspot.search_companies` | `HubSpot.Companies.Search` | no | hubspot, crm, companies, read, search |
| `hubspot.list_recent_companies` | `HubSpot.Companies.ListRecent` | no | hubspot, crm, companies, read, list |
| `hubspot.create_deal` | `HubSpot.Deals.Create` | yes | hubspot, crm, deals, write |
| `hubspot.get_deal` | `HubSpot.Deals.Get` | no | hubspot, crm, deals, read |
| `hubspot.update_deal` | `HubSpot.Deals.Update` | yes | hubspot, crm, deals, write |
| `hubspot.delete_deal` | `HubSpot.Deals.Delete` | yes | hubspot, crm, deals, write, delete |
| `hubspot.search_deals` | `HubSpot.Deals.Search` | no | hubspot, crm, deals, read, search |
| `hubspot.list_recent_deals` | `HubSpot.Deals.ListRecent` | no | hubspot, crm, deals, read, list |

#### Skill Parameters by Operation Type

**Create skills**:

| Object | Required | Optional |
|--------|----------|----------|
| Contact | `email` | `first_name`, `last_name`, `phone`, `company`, `properties` |
| Company | `name` | `domain`, `website`, `industry`, `description`, `properties` |
| Deal | `dealname` | `pipeline`, `dealstage`, `amount`, `closedate`, `description`, `properties` |

**Get skills**: `id` (required)

**Update skills**: `id` (required), plus same optional fields as create

**Delete skills**: `id` (required)

**Search skills**: `query` (required), `search_by` (optional, enum per object), `limit` (optional, default 10)

**List recent skills**: `limit` (optional, default 10)

---

### 5. Integration Registry Changes

**File**: `lib/assistant/integrations/registry.ex`

Add `:hubspot` to `default_integrations/0`:

```elixir
alias Assistant.Integrations.HubSpot

def default_integrations do
  %{
    drive: Drive,
    gmail: Gmail,
    calendar: Calendar,
    hubspot: HubSpot.Client,          # <-- ADD
    openai: OpenAI,
    openrouter: OpenRouter,
    web_fetcher: HttpFetcher,
    web_extractor: HtmlExtractor
  }
end
```

This maps `:hubspot` to `Assistant.Integrations.HubSpot.Client` so skill handlers
retrieve it via `Map.get(context.integrations, :hubspot)` -- the standard nil-check
pattern. In tests, this can be replaced with a mock module.

The `Skills.Context` type already has `optional(:hubspot) => module()` -- no change needed.

---

### 6. Auth / Context Threading

**Pattern**: API key resolved in handler, not in context builder.

```
SubAgent.build_skill_context/2
    → Sets context.integrations[:hubspot] = HubSpot.Client  (via Registry)
    → Does NOT resolve HubSpot API key (unlike Google token)

Skill Handler.execute/2
    → Checks context.integrations[:hubspot] (nil-check pattern)
    → Resolves API key: IntegrationSettings.get(:hubspot_api_key)
    → Calls hubspot.create_contact(api_key, properties)
```

**Rationale**: The Google token resolution is lazy and per-user (expensive, needs
OAuth refresh). The HubSpot key is a single org-wide value that's cheap to look up.
Resolving it in the handler keeps the context builder simple and avoids coupling it
to HubSpot-specific logic.

---

## Error Handling

### Client-Level Errors

All client methods return tagged tuples:

| Pattern | Meaning |
|---------|---------|
| `{:ok, data}` | Success |
| `{:error, {:api_error, status, message}}` | HubSpot API returned a non-success HTTP status |
| `{:error, {:request_failed, reason}}` | Network/connection failure |

### Handler-Level Errors

Handlers translate client errors into `%Result{status: :error}`:

```elixir
case hubspot.create_contact(api_key, properties) do
  {:ok, contact} ->
    {:ok, %Result{status: :ok, content: "Contact created successfully.\n..."}}

  {:error, {:api_error, 409, _}} ->
    {:ok, %Result{status: :error, content: "A contact with this email already exists."}}

  {:error, {:api_error, _status, message}} ->
    {:ok, %Result{status: :error, content: "HubSpot API error: #{message}"}}

  {:error, {:request_failed, reason}} ->
    {:ok, %Result{status: :error, content: "Failed to reach HubSpot: #{Exception.message(reason)}"}}
end
```

Notable HubSpot-specific HTTP status codes:

| Status | Meaning | Handler response |
|--------|---------|-----------------|
| 201 | Created | Success (create) |
| 200 | OK | Success (get, update, search, list) |
| 204 | No Content | Success (delete) |
| 400 | Validation error | Show message from API |
| 401 | Auth error | "HubSpot API key is invalid. Check Settings." |
| 404 | Not found | "No {object} found with ID {id}." |
| 409 | Conflict (duplicate) | "A {object} with this {field} already exists." |
| 429 | Rate limit | "HubSpot rate limit exceeded. Try again shortly." |

---

## Data Flow

### Create Contact Example

```
1. User: "Create a contact for jane@example.com"
2. LLM selects hubspot.create_contact skill
3. SubAgent dispatches with flags: {"email": "jane@example.com"}
4. Handler:
   a. context.integrations[:hubspot] → HubSpot.Client (not nil)
   b. IntegrationSettings.get(:hubspot_api_key) → "pat-xxx"
   c. Validate flags (email required)
   d. Build properties: %{"email" => "jane@example.com"}
   e. HubSpot.Client.create_contact("pat-xxx", properties)
5. Client:
   a. POST https://api.hubapi.com/crm/v3/objects/contacts
   b. Headers: Authorization: Bearer pat-xxx
   c. Body: {"properties": {"email": "jane@example.com"}}
6. API returns 201 with created contact
7. Client returns {:ok, %{id: "123", properties: %{...}}}
8. Handler formats Result:
   "Contact created successfully.
    ID: 123
    Email: jane@example.com"
```

### Search Deals Example

```
1. User: "Find deals related to Acme"
2. LLM selects hubspot.search_deals with flags: {"query": "Acme"}
3. Handler:
   a. Nil-check hubspot integration
   b. Resolve API key
   c. parse_limit(flags["limit"]) → 10
   d. search_by = flags["search_by"] || "name"
   e. HubSpot.Client.search_deals(api_key, "dealname", "CONTAINS_TOKEN", "Acme", 10)
4. Client:
   a. POST .../crm/v3/objects/deals/search
   b. Body: filter on dealname CONTAINS_TOKEN "Acme", limit 10
5. Client returns {:ok, [deal1, deal2, ...]}
6. Handler formats with Helpers.format_object_list/3
```

---

## Technology Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| HTTP client | Req (existing) | Already used by HubSpot.Client for health_check |
| API version | CRM v3 | Current HubSpot standard; matches reference TS implementation |
| Auth method | Bearer token | HubSpot Private App tokens; already configured in IntegrationSettings |
| Key resolution | In-handler via IntegrationSettings | Simple, explicit, no context builder coupling |
| Module injection | Integration registry | Enables test mocking; matches existing pattern |
| Skill naming | `hubspot.{action}_{object}` | Consistent with project conventions |
| Response format | Text blocks | Matches email/calendar skill output style |

---

## Testing Strategy

### Client Tests

- Mock HTTP responses with `Bypass` (configurable `base_url` already supported).
- Test each public method for success and error cases.
- Test `normalize_object/1` for API response shape variations.

### Handler Tests

- Inject mock `hubspot` module via `context.integrations`.
- Test nil-check pattern (integration not configured).
- Test missing API key scenario.
- Test flag validation (missing required params).
- Test successful execution and response formatting.
- Test error translation (409 conflict, 404 not found, etc.).

### Integration Tests

- Verify skills are loadable from `priv/skills/hubspot/*.md`.
- Verify registry includes `:hubspot` in default integrations.
- Verify handler modules are resolvable from skill definitions.

---

## Implementation Roadmap

### Phase 1: Client Expansion (Task #2)

1. Add generic `crm_*` private functions to `HubSpot.Client`
2. Add public methods for all 18 operations (6 per object type)
3. Add `normalize_object/1` and `build_search_body/3` helpers
4. Write Bypass-based tests

**Files modified**: `lib/assistant/integrations/hubspot/client.ex`
**Files created**: `test/assistant/integrations/hubspot/client_test.exs`

### Phase 2: Skill Handlers and Definitions (Task #3)

1. Create `HubSpot.Helpers` module
2. Create 18 skill handler modules (6 per object subdirectory)
3. Create 18 skill definition markdown files plus `SKILL.md`
4. Write handler unit tests with mock integration injection

**Files created**:
- `lib/assistant/skills/hubspot/helpers.ex`
- `lib/assistant/skills/hubspot/contacts/*.ex` (6 files)
- `lib/assistant/skills/hubspot/companies/*.ex` (6 files)
- `lib/assistant/skills/hubspot/deals/*.ex` (6 files)
- `priv/skills/hubspot/*.md` (19 files)
- `test/assistant/skills/hubspot/**/*_test.exs`

### Phase 3: Registry Wiring (Task #4)

1. Add `:hubspot` to `Integrations.Registry.default_integrations/0`
2. Update `@doc` to list the new integration

**Files modified**: `lib/assistant/integrations/registry.ex`

### Parallelization

Tasks #3 and #4 can run in parallel after Task #2 completes. Task #3 is the largest
(18 handlers + 19 markdown files) and could be split across multiple coders working
on contacts, companies, and deals concurrently -- no shared files between the three
object type subdirectories.

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| HubSpot API rate limits | Medium | Skill returns error | Return friendly message; no retry in first pass |
| Property names differ from TS reference | Low | Incorrect API calls | Verify against HubSpot API docs during CODE phase |
| `properties` JSON flag parsing | Medium | User passes invalid JSON | Validate with `Jason.decode` in handler; return clear error |
| Large search results | Medium | Context window pressure | `parse_limit` caps at 50; `Result.truncate_content` as backstop |
| Delete is destructive (actually archives) | Low | Data concern | `confirm: true` on delete skills; note "archive" in response |

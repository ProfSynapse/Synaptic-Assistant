# Synaptic Cloud: Architecture & Business Model Research

> Prepared: 2026-02-20
> Status: PACT Prepare Phase — Research Complete

---

## Executive Summary

Turning Synaptic Assistant into a paid cloud product follows a well-proven path blazed by n8n, PostHog, Sentry, and Outline. The recommended model is **open-core with usage-based billing**: the self-hosted desktop app remains free forever, while Synaptic Cloud offers managed hosting with metered pricing based on storage (transcripts, memories, documents) and AI usage (LLM tokens, voice minutes). The technical architecture should start with **row-level tenant isolation** on a shared PostgreSQL database, evolving to **Neon database-per-tenant** at scale. Billing integrates through `stripity_stripe` with Stripe's metered billing API. Infrastructure costs for a small team start at ~$50-150/month on Fly.io and scale linearly with tenants.

This document covers comparable business models, multi-tenant architecture options, billing integration, database provisioning, infrastructure topology, and a phased roadmap.

---

## 1. Comparable Open-Core Business Models

### 1.1 n8n (Primary Model)

n8n is the closest analog to Synaptic Assistant's intended model.

| Aspect | Details |
|--------|---------|
| **License** | Sustainable Use License (fair-code); source-available, restricts commercial redistribution |
| **Self-hosted** | Community Edition: free, unlimited workflow executions |
| **Cloud tiers** | Starter: EUR 24/mo (2,500 executions), Pro: EUR 60/mo (10,000 executions), Enterprise: custom |
| **Billing model** | Per-execution (not per-step); one workflow run = one execution regardless of complexity |
| **Cloud-only features** | Managed infrastructure, automatic updates, support SLA |
| **Enterprise-gated** | SSO/SAML, audit logs, Git version control, multi-environment, advanced permissions |
| **2026 change** | Self-hosted Business plan now introduces per-execution fees for enterprise features |

**Key insight**: n8n's core functionality is identical between self-hosted and cloud. The cloud tier sells convenience (managed hosting, zero-ops) and enterprise compliance (SSO, audit logs). This is the recommended model for Synaptic.

Sources:
- [n8n Pricing](https://n8n.io/pricing/)
- [n8n Sustainable Use License](https://docs.n8n.io/sustainable-use-license/)
- [n8n Choose Your n8n](https://docs.n8n.io/choose-n8n/)

### 1.2 PostHog

| Aspect | Details |
|--------|---------|
| **License** | MIT (core), proprietary (some cloud features) |
| **Self-hosted** | Free, recommended up to ~100k events/month; Kubernetes install no longer supported for new deploys |
| **Cloud billing** | Per-product usage-based: free monthly quota per module, then pay-as-you-go |
| **Free quotas** | 1M events, 5K recordings, 1M flag requests, 100K exceptions, 1.5K survey responses |
| **Cloud-only** | Dashboard subscriptions, SAML, RBAC, some add-ons (session replay, surveys, feature flags) |
| **Infrastructure** | Self-hosted minimum: 4 vCPU, 16 GB RAM, 30 GB disk |

**Key insight**: PostHog pioneered per-product metering where each module has its own free tier and billing rate. This works well when a product has distinct measurable dimensions (Synaptic has: transcripts, memories, AI tokens, storage).

Sources:
- [PostHog Pricing Breakdown](https://livesession.io/blog/posthog-pricing-breakdown-how-much-does-posthog-cost)
- [PostHog GitHub](https://github.com/PostHog/posthog)

### 1.3 Sentry

| Aspect | Details |
|--------|---------|
| **License** | FSL (Functional Source License); becomes Apache 2.0 after 2 years |
| **Self-hosted** | Free, equivalent to Business plan features; complex infrastructure |
| **Cloud tiers** | Developer (free, 5K errors/mo, 1 user), Team ($26/mo, 50K errors), Business ($80/mo), Enterprise (custom) |
| **Billing model** | Error/event-based with reserved volumes + pay-as-you-go overflow |
| **Cloud-only** | Lower operational burden; self-hosted requires significant DevOps investment |

**Key insight**: Sentry's "reserved volumes" model (buy a quota at a discount, overflow at higher rate) is worth considering for predictable pricing.

Sources:
- [Sentry Pricing](https://docs.sentry.io/pricing/)
- [Sentry Self-Hosted vs Cloud](https://sentry.io/resources/self-hosted-vs-cloud/)

### 1.4 Outline

| Aspect | Details |
|--------|---------|
| **License** | BSL (Business Source License) |
| **Self-hosted** | Free, full features; requires PostgreSQL + Redis + S3-compatible storage |
| **Cloud pricing** | $10-20/user/month; teams >200 get custom pricing |
| **Billing model** | Per-seat (not usage-based) |
| **Self-hosting cost** | ~$10-20/month on Railway/DigitalOcean for small teams |

**Key insight**: Outline uses per-seat pricing which is simpler but less aligned with Synaptic's value proposition. Usage-based is better for an AI assistant where value correlates with usage, not headcount.

Sources:
- [Outline Pricing](https://www.getoutline.com/pricing)
- [Outline Hosting Docs](https://docs.getoutline.com/s/hosting/doc/hosting-outline-nipGaCRBDu)

### 1.5 Comparison Matrix

| Dimension | n8n | PostHog | Sentry | Outline | **Synaptic (Recommended)** |
|-----------|-----|---------|--------|---------|---------------------------|
| Billing model | Per-execution | Per-event per-product | Per-error with reserves | Per-seat | **Per-storage + AI usage** |
| Free tier | Unlimited (self-host) | 1M events/mo (cloud) | 5K errors/mo (cloud) | Self-host only | **Self-host unlimited** |
| Cloud entry price | EUR 24/mo | Free → usage | $26/mo | $10/user/mo | **$15-20/mo** |
| Enterprise gate | SSO, audit, Git | SAML, RBAC | Priority support | Custom pricing | **SSO, team workspaces** |
| Self-host complexity | Moderate (Docker) | High (K8s deprecated) | High | Moderate | **Low (desktop app)** |

---

## 2. Multi-Tenant Architecture for Phoenix/Elixir

### 2.1 Isolation Strategies Compared

| Strategy | Data Isolation | Complexity | Scale Limit | Cost | Best For |
|----------|---------------|------------|-------------|------|----------|
| **Row-Level (tenant_id column)** | Application-enforced | Low | 10K+ tenants | Lowest | MVP, shared-schema apps |
| **Row-Level + Postgres RLS** | DB-enforced | Medium | 10K+ tenants | Low | Production with security guarantees |
| **Schema-per-tenant (Triplex)** | Schema-level | Medium | ~1K tenants | Medium | Mid-scale, regulatory compliance |
| **Database-per-tenant (Neon)** | Instance-level | High | Unlimited | Higher | Enterprise, full isolation |

### 2.2 Recommended Progression

**Stage 1 (MVP, 0-500 users): Row-Level Isolation with Postgres RLS**

Add a `tenant_id` column to all cloud-specific tables. Use Postgres Row-Level Security policies for database-enforced isolation. This is the simplest approach and works with a single Ecto Repo.

Implementation in Ecto:
- Add `tenant_id` (UUID) to all multi-tenant tables
- Create Postgres RLS policies on each table
- Set `current_setting('app.tenant_id')` at the start of each request via a Plug
- All queries automatically filtered by RLS without application-level changes

Elixir libraries:
- [ecto_row_level_security](https://github.com/mbuhot/ecto_row_level_security) — demonstration/reference
- [ecto-tenant-rls](https://github.com/bamorim/ecto-tenant-rls) — experimental RLS with Ecto

Known pitfall: Thread-local storage for tenant ID can leak between requests in connection pools. Must reset `app.tenant_id` in a post-response handler or use `Ecto.Repo.put_dynamic_repo/1` with proper scoping.

**Stage 2 (Growth, 500-5000 users): Schema-per-tenant (Triplex)**

If regulatory or customer requirements demand stronger isolation:
- [Triplex](https://github.com/ateliware/triplex) — mature Elixir library for PostgreSQL schema-based multi-tenancy
- Creates/manages per-tenant schemas automatically
- Ecto `prefix:` option routes queries to correct schema
- Migrations run per-tenant via `Triplex.migrate/2`

Trade-offs:
- More complex migrations (run N times for N tenants)
- Schema count becomes a PostgreSQL scaling concern past ~1K schemas
- Excellent data isolation without separate database instances

**Stage 3 (Scale, 5000+ users or enterprise): Database-per-tenant via Neon**

Neon's serverless Postgres is purpose-built for database-per-tenant:
- Provision a Neon project per tenant via the Neon API
- Scale-to-zero: inactive tenant databases consume zero compute
- $0.35/GB-month storage (reduced from $1.75 in 2025)
- Scale plan: up to 1,000 projects included; extra 500 for $50/month
- Agent Plan available for platforms provisioning thousands of databases

This is the ultimate isolation model but adds connection management complexity.

### 2.3 Ecto Multi-Tenancy Support

Ecto has first-class support for multi-tenancy via query prefixes:
- `Ecto.Query` accepts a `:prefix` option that maps to PostgreSQL DDL schemas
- A single connection pool serves all tenants
- `Repo.put_dynamic_prefix/1` can set prefix per-process

Official documentation: [Multi-tenancy with query prefixes](https://hexdocs.pm/ecto/multi-tenancy-with-query-prefixes.html)

---

## 3. Usage-Based Billing with Stripe

### 3.1 stripity_stripe Library

The [stripity_stripe](https://github.com/beam-community/stripity-stripe) library (v3.2.0) is the standard Elixir Stripe integration. Key modules for metered billing:

| Module | Purpose |
|--------|---------|
| `Stripe.Customer` | Create/manage customer records |
| `Stripe.Subscription` | Manage subscriptions with metered prices |
| `Stripe.UsageRecord` | Report metered usage to Stripe |
| `Stripe.BillingPortal.Session` | Self-service billing portal for customers |
| `Stripe.Price` | Define metered pricing (usage_type: "metered") |

### 3.2 Metered Billing Flow

```
1. User signs up → Create Stripe Customer
2. User subscribes → Create Subscription with metered Price(s)
3. Ongoing usage → Report UsageRecords to Stripe periodically
4. End of billing period → Stripe auto-calculates invoice from usage
5. Self-service → BillingPortal.Session for plan management
```

### 3.3 What to Meter for Synaptic Cloud

| Metric | Unit | How to Track | Suggested Price |
|--------|------|--------------|-----------------|
| **Transcript storage** | GB-month | Sum of transcript text sizes per tenant | $0.50/GB-month |
| **Memory storage** | GB-month | Sum of memory/embedding sizes per tenant | $0.50/GB-month |
| **Document storage** | GB-month | Drive/file attachments | $0.25/GB-month |
| **AI token usage** | 1K tokens | LLM API calls proxied through cloud | Pass-through + 20% margin |
| **Voice minutes** | Minutes | ElevenLabs TTS usage | Pass-through + 20% margin |
| **Workflow executions** | Execution | Oban job completions for workflow runs | $0.01/execution |

### 3.4 Implementation Architecture

New Phoenix context: `Assistant.Billing`

```
lib/assistant/billing/
  billing.ex           # Context module — public API
  stripe_client.ex     # Stripe API wrapper using stripity_stripe
  usage_tracker.ex     # GenServer tracking usage metrics in-memory, flushing to Stripe
  metering.ex          # Ecto queries for calculating tenant usage
  subscription.ex      # Subscription management logic
```

New schemas:
- `billing_customers` — links tenant_id to Stripe customer_id
- `billing_subscriptions` — tracks active subscription + plan tier
- `usage_records` — local ledger of usage before reporting to Stripe

### 3.5 Bling Library (Alternative)

[Bling](https://elixirforum.com/t/bling-stripe-subscription-management-for-phoenix/56137) is a newer Elixir library specifically for Phoenix + Stripe subscription management. Worth evaluating as it may reduce boilerplate compared to raw stripity_stripe.

Sources:
- [stripity_stripe docs](https://hexdocs.pm/stripity_stripe/)
- [Stripe.UsageRecord](https://hexdocs.pm/stripity_stripe/Stripe.UsageRecord.html)
- [Stripe metered billing docs](https://docs.stripe.com/billing/subscriptions/usage-based)
- [Stripe BillingPortal.Session](https://hexdocs.pm/stripity_stripe/Stripe.BillingPortal.Session.html)

---

## 4. OAuth-Provisioned Database Integrations

### 4.1 Neon (Recommended)

Neon is the strongest option for programmatic database provisioning.

**Claimable Postgres API**:
- Single HTTP request creates a database and returns a connection string
- User does NOT need a Neon account to get started
- Database works immediately; user can optionally "claim" ownership later
- Unclaimed databases expire after 72 hours; claimed databases persist
- REST API returns: project ID, connection string, claim URL, expiration

**OAuth Integration**:
- Full OAuth2 flow for creating/managing Neon projects on behalf of users
- No need for users to share credentials
- Platform can manage thousands of tenant databases programmatically

**Agent Plan** (announced 2025):
- Designed for platforms like Synaptic that provision databases for users
- Custom project/branch limits, higher API rate limits
- Includes Neon Auth and Data API at no extra cost
- Used by Replit, v0, Databutton

**Pricing** (post-2025 reduction):
- Free: 100 CU-hours/project/month, 0.5 GB storage, up to 100 projects
- Launch: Usage-based, no minimum, up to 100 projects
- Scale: Up to 1,000 projects included, $0.35/GB-month storage

Sources:
- [Neon Multitenancy Guide](https://neon.com/docs/guides/multitenancy)
- [Neon Claimable Postgres](https://neon.com/docs/reference/claimable-postgres)
- [Neon Database-per-Tenant](https://neon.com/use-cases/database-per-tenant)
- [Neon Pricing](https://neon.com/pricing)

### 4.2 Supabase (Alternative)

Supabase offers similar capabilities through its Management API:

**Management API**:
- Programmatic project creation, configuration, and management
- Two auth methods: Personal Access Tokens (long-lived) and OAuth2 (delegated)
- OAuth2 allows creating/managing Supabase projects on behalf of users
- Users can take ownership of their projects via authorization flow

**Bundled services per project**:
- Database (Postgres)
- Auth (built-in user management)
- Edge Functions
- Storage (S3-compatible)
- Realtime subscriptions

**Trade-offs vs Neon**:
- Supabase bundles more services (auth, storage, edge functions) but at higher cost
- Neon is pure Postgres with better scale-to-zero and lower per-tenant cost
- Supabase is better if you want a full BaaS per tenant
- Neon is better if you only need database isolation (Synaptic already has its own auth, storage, etc.)

**Recommendation**: Neon for database provisioning. Synaptic already handles auth (Phoenix), file storage, and real-time (LiveView PubSub). Paying for Supabase's bundled services would be redundant.

Sources:
- [Supabase Management API](https://supabase.com/docs/reference/api/introduction)
- [Supabase for Platforms](https://supabase.com/docs/guides/integrations/supabase-for-platforms)

---

## 5. Synaptic Cloud Infrastructure Architecture

### 5.1 Existing Contexts (Current State)

The codebase already has these Phoenix contexts:
- `Assistant.Accounts` — user auth, settings, OAuth tokens
- `Assistant.Integrations` — Gmail, Calendar, Drive
- `Assistant.Skills` — AI skill execution
- `Assistant.Workflows` — workflow management and scheduling
- `Assistant.Memory` / `Assistant.Transcripts` — conversation storage
- `Assistant.Orchestrator` — AI orchestration
- `Assistant.Scheduler` — Oban job scheduling

### 5.2 New Contexts Needed for Cloud

| Context | Purpose | Priority |
|---------|---------|----------|
| `Assistant.Tenants` | Tenant management, plan tiers, tenant settings | v1 |
| `Assistant.Billing` | Stripe integration, usage metering, subscription management | v1 |
| `Assistant.Cloud.Provisioning` | Neon database provisioning, connection management | v2 |
| `Assistant.Cloud.Sync` | Desktop-to-cloud sync protocol | v2 |
| `Assistant.Cloud.Admin` | Admin dashboard, tenant monitoring, usage analytics | v2 |
| `Assistant.Teams` | Multi-user workspaces, invitations, roles | v3 |

### 5.3 How Desktop App Connects to Cloud vs Local

The architecture uses a **mode flag** to determine data routing:

```
                    ┌──────────────────┐
                    │  Synaptic App    │
                    │  (Tauri + Burrito│
                    │   + Phoenix)     │
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │  Mode Router     │
                    │  (local / cloud) │
                    └────┬────────┬────┘
                         │        │
              ┌──────────▼──┐  ┌──▼───────────┐
              │ LOCAL MODE  │  │ CLOUD MODE   │
              │             │  │              │
              │ SQLite DB   │  │ API Client   │
              │ (embedded)  │  │ → Cloud API  │
              │             │  │              │
              │ All data    │  │ Data on      │
              │ stays local │  │ Neon Postgres│
              └─────────────┘  └──────────────┘
```

**Local mode** (default, free):
- Phoenix runs embedded via Burrito sidecar
- SQLite database (via `ecto_sqlite3`)
- All data stays on the user's machine
- No network dependency except for LLM API calls

**Cloud mode** (paid):
- Phoenix server runs on Fly.io (or similar)
- PostgreSQL on Neon (per-tenant)
- User authenticates via OAuth/magic link
- Real-time sync via Phoenix Channels / LiveView

**Hybrid mode** (future, v3):
- Local-first with cloud sync
- Works offline, syncs when connected
- CRDT-based conflict resolution for concurrent edits

### 5.4 Web UI (Browser Access Without Desktop App)

For cloud users, a full web UI is essential — they should not need to install the desktop app.

Since Synaptic already uses Phoenix LiveView, the web UI is essentially the same codebase:
- LiveView renders the same UI in both desktop (Tauri webview) and browser
- Authentication via `Assistant.Accounts` (already exists)
- Real-time via Phoenix PubSub (already exists)
- No separate frontend framework needed

**Key differences for web deployment**:
- CSRF protection and session management (Phoenix built-in)
- CSP headers for browser security
- Subdomain-based tenant routing (e.g., `{tenant}.synaptic.cloud`)
- CDN for static assets (already handled by Phoenix static plug)

### 5.5 Infrastructure Topology

**Minimal viable infrastructure** (v1, <100 users):

| Component | Service | Est. Cost/Month |
|-----------|---------|-----------------|
| Phoenix app server | Fly.io (1x shared-cpu-1x, 256MB) | $3-7 |
| PostgreSQL (platform DB) | Fly.io Postgres or Neon Free | $0-15 |
| Tenant databases | Neon Free tier (100 projects) | $0 |
| Redis (PubSub, caching) | Upstash or Fly.io | $0-10 |
| Object storage (files) | Tigris (Fly.io) or S3 | $0-5 |
| Email (transactional) | Swoosh + Resend/Postmark | $0-20 |
| **Total** | | **$3-57** |

**Growth infrastructure** (v2, 100-1000 users):

| Component | Service | Est. Cost/Month |
|-----------|---------|-----------------|
| Phoenix app (2x instances) | Fly.io (shared-cpu-2x, 512MB each) | $15-30 |
| Platform PostgreSQL | Neon Launch plan | $20-50 |
| Tenant databases | Neon Launch/Scale (100-1000 projects) | $50-200 |
| Redis | Upstash Pro | $10-30 |
| Object storage | S3/Tigris | $10-50 |
| CDN | Cloudflare (free tier) | $0 |
| Monitoring | Fly.io metrics + Sentry | $0-30 |
| **Total** | | **$105-390** |

**Scale infrastructure** (v3, 1000+ users):

| Component | Service | Est. Cost/Month |
|-----------|---------|-----------------|
| Phoenix cluster (3+ nodes) | Fly.io (dedicated-cpu) | $50-200 |
| Platform PostgreSQL | Neon Scale | $50-200 |
| Tenant databases | Neon Scale (1000+ projects) | $200-1000 |
| Redis cluster | Upstash or self-managed | $30-100 |
| Object storage | S3 | $50-200 |
| CDN | Cloudflare Pro | $20 |
| Monitoring stack | Sentry + Grafana Cloud | $30-100 |
| **Total** | | **$430-1820** |

---

## 6. Phased Roadmap

### Phase 1: Cloud MVP (v1)

**Goal**: Minimum viable cloud product — single user can use Synaptic via browser.

**Build**:
- [ ] `Assistant.Tenants` context — tenant CRUD, plan assignment
- [ ] `Assistant.Billing` context — Stripe Customer + Subscription management
- [ ] Row-level tenant isolation (tenant_id column + Postgres RLS policies)
- [ ] User registration and authentication for cloud (extend existing `Accounts`)
- [ ] Web deployment configuration (Fly.io, Neon, environment configs)
- [ ] Usage metering GenServer — track storage, report to Stripe
- [ ] Stripe webhook handler for subscription lifecycle events
- [ ] Billing portal integration (self-service plan management)
- [ ] Landing page / marketing site

**Pricing (v1)**:
- Free tier: 100MB storage, 10K AI tokens/month, 50 workflow executions
- Starter: $15/month — 1GB storage, 100K AI tokens, 500 workflow executions
- Pro: $40/month — 10GB storage, 500K AI tokens, unlimited workflows

**Infrastructure**: Fly.io + Neon free tier. Cost: ~$10-50/month.

**Timeline estimate**: 4-6 weeks for a focused team.

### Phase 2: Growth Features (v2)

**Goal**: Multi-user workspaces, stronger isolation, operational maturity.

**Build**:
- [ ] Team/workspace support — invite members, role-based access
- [ ] Neon database-per-tenant provisioning (migrate from RLS to per-tenant DB for paid users)
- [ ] Desktop-to-cloud migration tool (export local SQLite, import to cloud Postgres)
- [ ] Admin dashboard — tenant usage monitoring, health checks
- [ ] Rate limiting and abuse prevention
- [ ] Automated backup and restore
- [ ] Cloud-specific integrations (Slack bot, API access)
- [ ] SOC 2 compliance preparation

**Pricing (v2)**:
- Add Team tier: $30/user/month — shared workspace, 5GB/user, collaborative features
- Enterprise: Custom — SSO/SAML, audit logs, dedicated database, SLA

**Infrastructure**: Neon Scale plan for tenant databases. Cost: ~$100-400/month.

### Phase 3: Platform & Enterprise (v3)

**Goal**: Full platform with enterprise features and hybrid mode.

**Build**:
- [ ] Hybrid sync (local-first with cloud backup, CRDT-based)
- [ ] SSO/SAML integration (enterprise gate)
- [ ] Audit logging (enterprise gate)
- [ ] API access for programmatic integrations
- [ ] Marketplace for community skills/workflows
- [ ] Custom model hosting (bring-your-own LLM key OR use Synaptic's)
- [ ] White-label option for enterprise resellers
- [ ] Multi-region deployment

**Pricing (v3)**:
- Enterprise: Custom — SSO, audit logs, dedicated infra, SLA, white-label
- Platform: Revenue share for marketplace skill/workflow authors

---

## 7. Recommendations

### 7.1 Business Model

1. **Follow the n8n model**: Self-hosted is free forever with full functionality. Cloud sells convenience and compliance.
2. **Usage-based billing** (PostHog-style): Meter by storage and AI usage, not seats. AI assistants create variable value per user.
3. **Generous free tier**: Critical for adoption. 100MB storage + limited AI tokens lets users try before buying.
4. **Enterprise gate on compliance features**: SSO, audit logs, dedicated databases — these justify premium pricing.

### 7.2 Technical Architecture

1. **Start with RLS** (row-level security): Lowest complexity, works at MVP scale. Add `tenant_id` to cloud tables, enable Postgres RLS.
2. **Graduate to Neon per-tenant**: When customers need isolation guarantees or regulatory compliance.
3. **Use stripity_stripe**: Mature, well-maintained, covers all metered billing needs.
4. **Neon over Supabase**: Synaptic already has auth, storage, and real-time. Pay only for what you need (database).
5. **Fly.io for hosting**: Best Elixir ecosystem support, global edge deployment, generous free tier.

### 7.3 What NOT to Build in v1

- Team/multi-user workspaces (complexity explosion)
- Hybrid sync/CRDT (research project unto itself)
- Custom model hosting (just pass through API keys)
- Marketplace (need users first)
- Multi-region (premature optimization)

---

## 8. Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Low cloud adoption (users prefer self-host) | Medium | High | Generous free tier; cloud-exclusive convenience features (zero-ops, mobile access) |
| Neon pricing changes post-Databricks acquisition | Low | Medium | Abstract database provisioning behind interface; Supabase as fallback |
| Stripe metered billing complexity | Low | Medium | Start simple (storage only); add AI metering later |
| Tenant data leakage (RLS misconfiguration) | Low | Critical | Comprehensive RLS tests; gradual migration to per-tenant DB |
| Infrastructure costs exceed revenue at scale | Medium | High | Usage-based pricing with margins; reserved Neon capacity at volume |
| Desktop-to-cloud migration data loss | Medium | High | Thorough migration tooling; dry-run validation; rollback capability |

---

## 9. References

### Open-Core Business Models
- [n8n Pricing](https://n8n.io/pricing/)
- [n8n Sustainable Use License](https://docs.n8n.io/sustainable-use-license/)
- [PostHog Pricing](https://livesession.io/blog/posthog-pricing-breakdown-how-much-does-posthog-cost)
- [Sentry Pricing](https://docs.sentry.io/pricing/)
- [Sentry Self-Hosted vs Cloud](https://sentry.io/resources/self-hosted-vs-cloud/)
- [Outline Pricing](https://www.getoutline.com/pricing)

### Multi-Tenant Architecture
- [Ecto Multi-tenancy with Query Prefixes](https://hexdocs.pm/ecto/multi-tenancy-with-query-prefixes.html)
- [Triplex — Elixir Multi-tenancy](https://github.com/ateliware/triplex)
- [Multitenancy in Elixir (Curiosum)](https://www.curiosum.com/blog/multitenancy-in-elixir)
- [Ecto Row-Level Security Demo](https://github.com/mbuhot/ecto_row_level_security)
- [Ecto Tenant RLS](https://github.com/bamorim/ecto-tenant-rls)
- [AppSignal: Multi-tenant Phoenix](https://blog.appsignal.com/2023/11/21/setting-up-a-multi-tenant-phoenix-app-for-elixir.html)

### Billing & Stripe
- [stripity_stripe (HexDocs)](https://hexdocs.pm/stripity_stripe/)
- [Stripe.UsageRecord](https://hexdocs.pm/stripity_stripe/Stripe.UsageRecord.html)
- [Stripe Metered Billing](https://docs.stripe.com/billing/subscriptions/usage-based)
- [Stripe Billing Portal](https://hexdocs.pm/stripity_stripe/Stripe.BillingPortal.Session.html)
- [Bling — Phoenix Stripe Subscriptions](https://elixirforum.com/t/bling-stripe-subscription-management-for-phoenix/56137)
- [Sequin: Stripe Metered Billing](https://blog.sequin.io/stripe-metered-billing-simplified/)

### Database Provisioning
- [Neon Multitenancy](https://neon.com/docs/guides/multitenancy)
- [Neon Claimable Postgres](https://neon.com/docs/reference/claimable-postgres)
- [Neon Database-per-Tenant](https://neon.com/use-cases/database-per-tenant)
- [Neon Pricing](https://neon.com/pricing)
- [Supabase Management API](https://supabase.com/docs/reference/api/introduction)
- [Supabase for Platforms](https://supabase.com/docs/guides/integrations/supabase-for-platforms)

### Infrastructure
- [Fly.io Elixir Deployment](https://fly.io/docs/elixir/)
- [Phoenix SaaS Starter Kit](https://www.phoenixsaaskit.com/)
- [LiveSaaSKit](https://livesaaskit.com/)
- [Tauri + Elixir (CrabNebula)](https://crabnebula.dev/blog/tauri-elixir-phoenix/)

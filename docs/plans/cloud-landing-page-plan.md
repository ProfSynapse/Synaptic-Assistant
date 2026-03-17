# Implementation Plan: Cloud Landing Page

> Created: 2026-03-17
> Status: DRAFT
> Direction: Build a single scrollable public marketing page that feels cinematic and modern, while staying inside the existing Synaptic Assistant design language.

## Summary

This plan defines a public, single-page landing experience for Synaptic Assistant Cloud.

The page should feel:

- premium
- kinetic
- legible
- product-led
- unmistakably connected to the existing app

It should not look like a generic SaaS template.

The current design system already gives us strong visual primitives:

- Montserrat typography
- aqua / blue / purple brand gradients
- soft radial atmospherics
- glassy white cards with `sa-card`
- animated gradient CTAs with `sa-btn`
- rounded chips, pills, and bordered surfaces

The landing page should extend those patterns instead of introducing a second design language.

## Route Placement

### Recommended Route

Add the landing page as:

- `live "/cloud", MarketingLive, :index`

Place it in:

- `scope "/", AssistantWeb`
- `pipe_through [:browser]`
- inside the existing `live_session :current_settings_user`

Why:

- this page should work both for signed-out and signed-in visitors
- the existing `:browser` pipeline already gives us `current_scope`
- the existing `live_session :current_settings_user` already mounts current auth context without requiring login
- this avoids introducing a duplicate `live_session`

This means the route belongs alongside:

- `/setup`
- `/settings_users/register`
- `/settings_users/log-in`

and not inside the authenticated-only `live_session :require_authenticated_settings_user`.

### Template Wrapper

The LiveView template should start with:

```heex
<Layouts.app flash={@flash} current_scope={@current_scope}>
  ...
</Layouts.app>
```

Why:

- this follows the Phoenix 1.8 layout rule already used by the app
- it keeps flash handling and app shell consistency correct
- it preserves `current_scope` availability

## Product Narrative

The page should sell one idea:

> Bring your own model access. We handle the workspace, sync, memory, connectors, and orchestration.

That narrative should unfold top-to-bottom in one pass:

1. Brand and positioning
2. Product motion and “how it works”
3. Connectors and synced workspace
4. Memory + automation + approvals
5. Pricing and free tier
6. Final CTA

## Visual Direction

### Core Mood

Use a “signal field” aesthetic:

- large radial light pools
- layered translucent cards
- slow parallax orbs and mesh lines
- sticky product frame sections
- scrolling depth instead of busy microinteractions

The page should feel more like a control surface than a brochure.

### Reused Design Patterns

Preserve these existing patterns from the current app:

- gradient backgrounds from `assets/css/app.css`
- card surfaces matching `sa-card`
- CTA buttons matching `sa-btn`
- border radius and border tone matching `sa-border`
- app icons and chip styles from `sa-chip` and connector card surfaces

Do not switch to a black neon landing page or a generic Tailwind demo look.

## Page Architecture

### Section Order

1. Floating nav
2. Full-width hero banner
3. Product proof strip
4. Sticky “workspace orbit” section
5. Connector marquee
6. Capability grid
7. Pricing section
8. FAQ / trust strip
9. Final CTA footer

## Desktop Wireframe

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ NAV                                                                         │
│ Logo                     Product  Connectors  Pricing            Log in CTA │
├──────────────────────────────────────────────────────────────────────────────┤
│ HERO BANNER                                                                │
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │ “Your workspace, synced across tools. Your models. Our orchestration.”  │ │
│ │                                                                          │ │
│ │ Bring your own model access. We handle sync, memory, approvals, and      │ │
│ │ orchestration across the tools your team already uses.                   │ │
│ │                                                                          │ │
│ │ [Start Free] [See Pricing]                                               │ │
│ │ 25 MB free  •  $18/user/mo  •  10 GB included  •  $1/GB-month overage    │ │
│ │                                                                          │ │
│ │                    [large cinematic product scene]                       │ │
│ │                    [parallax glow field + floating cards]                │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
├──────────────────────────────────────────────────────────────────────────────┤
│ PROOF STRIP                                                                 │
│ [Bring your own inference] [Workspace sync] [Memory] [Approvals] [Flows]  │
├──────────────────────────────────────────────────────────────────────────────┤
│ STICKY STORY SECTION                                                        │
│ ┌────────────────────────────┬─────────────────────────────────────────────┐ │
│ │ Sticky narrative rail      │  Scroll-reactive product frame             │ │
│ │                            │                                             │ │
│ │ 01 Connect storage         │   [large browser / chat / workflow scene]  │ │
│ │ 02 Build shared memory     │   changes panel-by-panel as user scrolls    │ │
│ │ 03 Run workflows safely    │                                             │ │
│ └────────────────────────────┴─────────────────────────────────────────────┘ │
├──────────────────────────────────────────────────────────────────────────────┤
│ CONNECTOR MARQUEE                                                           │
│ Google  Microsoft  Box  Slack  Discord  Telegram  HubSpot  OpenAI ...     │
│ slowly scrolling right-to-left, repeating seamlessly                        │
├──────────────────────────────────────────────────────────────────────────────┤
│ CAPABILITIES                                                                │
│ ┌────────────────┐ ┌────────────────┐ ┌────────────────┐                   │
│ │ icon           │ │ icon           │ │ icon           │                   │
│ │ Workspace Sync │ │ Context + Mem. │ │ Talk Anywhere  │                   │
│ │ sentence       │ │ sentence       │ │ sentence       │                   │
│ └────────────────┘ └────────────────┘ └────────────────┘                   │
│ ┌────────────────┐ ┌────────────────┐ ┌────────────────┐                   │
│ │ icon           │ │ icon           │ │ icon           │                   │
│ │ Workflows      │ │ Approval Gates │ │ Secure by      │                   │
│ │ sentence       │ │ sentence       │ │ Default        │                   │
│ └────────────────┘ └────────────────┘ └────────────────┘                   │
├──────────────────────────────────────────────────────────────────────────────┤
│ PRICING                                                                     │
│    Free                          Pro                     Enterprise          │
│   25 MB                     $18 / user / month       Contact us             │
│ 3 connectors                10 GB included           SSO / admin controls   │
│ hard stop at limit          $1 / GB-month over 10GB custom limits / support │
│ [Start free]                [Start Pro]             [Contact Sales]         │
├──────────────────────────────────────────────────────────────────────────────┤
│ TRUST / FAQ                                                                 │
│ clear answers, storage language, BYO-model explanation                      │
├──────────────────────────────────────────────────────────────────────────────┤
│ FINAL CTA                                                                   │
│ “Start with 25 MB. Upgrade when your workspace becomes real.”               │
│ [Create account]                                                            │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Mobile Wireframe

```text
┌──────────────────────────────┐
│ Logo                 Menu    │
├──────────────────────────────┤
│ HERO BANNER                  │
│ Big statement                │
│ BYO inference copy           │
│ [Start Free] [See Pricing]   │
│ pricing microcopy            │
│ cinematic scene below        │
├──────────────────────────────┤
│ Proof chips                  │
│ [BYO model] [Memory] ...     │
├──────────────────────────────┤
│ Sticky product story         │
│ narrative card               │
│ visual card                  │
│ narrative card               │
│ visual card                  │
├──────────────────────────────┤
│ Connector marquee            │
├──────────────────────────────┤
│ 6 stacked capability cards   │
├──────────────────────────────┤
│ 3 pricing cards              │
├──────────────────────────────┤
│ FAQ                          │
├──────────────────────────────┤
│ Final CTA                    │
└──────────────────────────────┘
```

## Section Design

### 1. Floating Nav

Use:

- translucent bar
- blurred background
- compact logo lockup
- sticky top positioning after initial scroll

Content:

- logo
- Product
- Connectors
- Pricing
- Log in
- Start free

Behavior:

- transparent over hero at top
- gains background + border once page scrolls

### 2. Hero Banner

The hero should be one continuous full-width banner, not two separate boxes.

Structure:

- one dominant headline block
- one supporting paragraph
- primary and secondary CTA row
- one short pricing / plan line
- one integrated cinematic product scene beneath or behind the copy

This should feel like a single composition:

- copy and product visual belong to the same surface
- the background glow field spans edge to edge
- the product scene emerges from inside the hero rather than sitting in a neighboring card

Background:

- giant radial gradients
- one large faint orbit ring
- one subtle grid / line field

Motion:

- parallax layers move at different rates
- hero scene cards drift slowly
- initial reveal stagger on connected mount

ASCII:

```text
┌──────────────────────────────────────────────────────────────────────────┐
│ headline                                                                 │
│ support copy                                                             │
│ [Start Free] [See Pricing]                                               │
│ 25 MB free  •  $18/user/mo  •  10 GB included  •  $1/GB-month overage    │
│                                                                          │
│                floating product composition inside hero                  │
│                connector card  •  memory card  •  approval card          │
└──────────────────────────────────────────────────────────────────────────┘
```

### 3. Proof Strip

This should be a clean compression layer between hero and detail.

Use pill or chip surfaces for:

- Bring your own model access
- Sync docs into Markdown
- Shared memory
- Workflow automation
- Human approvals

### 4. Sticky Workspace Story

This is the main “sexy” section.

Layout:

- left narrative column with 3 to 4 story beats
- right sticky visual frame

As the user scrolls:

- each story beat becomes active
- the product visual updates
- glow color and card emphasis shift

Story beats:

1. Connect your workspace
2. Turn documents into searchable context
3. Build durable memory from conversations
4. Run workflows with guardrails

ASCII:

```text
┌──────────────────────────────────────────────────────────────────────┐
│ ┌──────────────────────┐  ┌───────────────────────────────────────┐ │
│ │ 01 Connect           │  │                                       │ │
│ │ Google / Microsoft   │  │        Sticky Product Frame           │ │
│ │ / Box                │  │                                       │ │
│ │                      │  │   [active card 1 highlighted]         │ │
│ ├──────────────────────┤  │   [inactive cards behind]             │ │
│ │ 02 Convert to md/csv │  │   [slow background depth motion]      │ │
│ ├──────────────────────┤  │                                       │ │
│ │ 03 Build memory      │  │                                       │ │
│ ├──────────────────────┤  └───────────────────────────────────────┘ │
│ │ 04 Add approvals     │                                            │
│ └──────────────────────┘                                            │
└──────────────────────────────────────────────────────────────────────┘
```

### 5. Connector Marquee

This section should show every app logo the product connects to and move them slowly from right to left.

Visual treatment:

- clean monochrome or lightly colored logo row
- duplicated track for seamless looping
- slow marquee motion
- pause or reduce motion on hover if needed

Content should include current and near-term connectors such as:

- Google
- Microsoft
- Box
- Slack
- Telegram
- Discord
- HubSpot
- OpenAI
- OpenRouter

Implementation note:

- use a duplicated logo track in pure CSS transform animation where possible
- only use JS if needed for responsive speed tuning
- reduce or disable marquee animation under `prefers-reduced-motion`

### 6. Capability Grid

Four cards is too compressed for the actual product story. This section should use six cards in a balanced grid.

Recommended desktop layout:

- `3 x 2` grid on desktop
- `2 x 3` on tablet
- stacked cards on mobile

Each card should have:

- one prominent icon
- one short label
- one sentence that explains what the capability actually does
- one small decorative animation or reactive detail

The cards should not just name features. They need to answer: what does this do for me?

Recommended cards:

- Workspace Sync
- Context That Compounds
- Talk Anywhere
- Automated Workflows
- Approval Gates
- Secure by Default

Recommended icons:

- Workspace Sync: `hero-arrow-path` or `hero-folder`
- Context That Compounds: `hero-circle-stack` or `hero-share`
- Talk Anywhere: `hero-chat-bubble-left-right`
- Automated Workflows: `hero-bolt` or `hero-cpu-chip`
- Approval Gates: `hero-hand-raised` or `hero-check-badge`
- Secure by Default: `hero-shield-check`

Suggested one-sentence copy:

- Workspace Sync: Connect cloud docs and shared drives so the assistant stays grounded in the same working files as your team.
- Context That Compounds: Turn documents, chats, and actions into durable memory the assistant can reuse instead of relearning.
- Talk Anywhere: Reach the assistant from the channels your team already lives in, without forcing everyone into a new interface.
- Automated Workflows: Put recurring work on rails so follow-ups, prep, and routine operations keep moving in the background.
- Approval Gates: Insert a human checkpoint before messages, edits, or actions that should never fire without review.
- Secure by Default: Keep access scoped, tool use bounded, and sensitive behavior inside explicit policy and approval controls.

Suggested card-level animation treatment:

- Workspace Sync: flowing connection line or subtle file-to-file pulse
- Context That Compounds: slowly expanding node cluster or orbiting chips
- Talk Anywhere: message pulse traveling across channel icons
- Automated Workflows: stepped progress path with moving highlight
- Approval Gates: split path that resolves after approval highlight
- Secure by Default: shield / lock glow with constrained motion field

These animations should be ambient and low-amplitude, not gimmicky.

Recommended card construction:

- icon lockup at the top of each card
- headline: short and concrete
- body: one sentence, 16 to 22 words
- footer detail: one small proof point, example, or icon row

Recommended final marketing copy for the six cards:

- Workspace Sync
  Connect cloud docs and shared drives so the assistant stays grounded in the same working files as your team.
- Context That Compounds
  Turn documents, chats, and actions into durable memory the assistant can reuse instead of relearning from scratch.
- Talk Anywhere
  Reach the assistant from the channels your team already uses, without forcing everyone into a new workflow or UI.
- Automated Workflows
  Put recurring work on rails so prep, follow-ups, reporting, and routine operations keep moving without constant manual handoffs.
- Approval Gates
  Require a human decision before high-impact messages, edits, or downstream actions go out.
- Secure by Default
  Keep access scoped, tools bounded, and sensitive behavior inside explicit policy and approval controls.

### 7. Pricing

This section should make pricing feel unusually understandable.

Use three cards:

- Free
- Pro
- Enterprise

and one slim explainer row:

- monthly average storage billing
- bring your own model access
- overage only above included storage
- enterprise plan requires contact

The overage language must be visually explicit. Do not bury it in footnote copy.

ASCII:

```text
┌────────────────────────────────────────────────────────────────────────────┐
│ Pricing                                                                    │
│                                                                            │
│ ┌──────────────────────┐ ┌────────────────────────────┐ ┌────────────────┐ │
│ │ Free                 │ │ Pro                        │ │ Enterprise     │ │
│ │ 25 MB                │ │ $18 / user / month         │ │ Contact us     │ │
│ │ Google/Microsoft/Box │ │ 10 GB included             │ │ SSO / controls │ │
│ │ Upgrade at limit     │ │ $1 / GB over 10 GB         │ │ custom terms   │ │
│ │ [Start free]         │ │ [Start Pro]                │ │ [Contact Sales]│ │
│ └──────────────────────┘ └────────────────────────────┘ └────────────────┘ │
│                                                                            │
│ billed on monthly average storage, not peak                                │
│ example: 12 GB average stored = 2 GB billable overage                      │
└────────────────────────────────────────────────────────────────────────────┘
```

### 8. FAQ / Trust Strip

Keep this short.

Questions to answer:

- Do I bring my own model access?
- What counts toward storage?
- What happens at the free limit?
- Which connectors are in free?

### 9. Final CTA

End with a large, calm panel.

Message:

- low friction
- clear free tier
- strong sign-up button

Suggested line:

> Start with 25 MB. Upgrade when your workspace becomes real.

## Motion System

### Motion Principles

Use fewer, larger motions:

- hero parallax
- reveal-on-enter
- sticky scene progression
- hover lift

Avoid:

- constant bouncing
- noisy counters
- too many independent moving parts

### Planned Interactions

#### Hero Parallax

Multiple decorative layers:

- far glow layer
- mid orbit ring layer
- foreground cards

All driven by one scroll hook.

#### Reveal-on-Enter

Cards, chips, and pricing blocks fade and rise in with stagger.

#### Sticky Story Transitions

Each story beat updates active state in the sticky scene.

#### Connector Marquee

One slow, continuous, right-to-left logo track with seamless looping.

#### Capability Card Hover

Tiny lift plus glow; no wobble.

## Phoenix / LiveView Implementation Notes

### LiveView Choice

Use a LiveView, not a controller-rendered static page.

Why:

- current app already uses LiveView heavily
- we can reuse hooks infrastructure in `priv/static/assets/app.js`
- `current_scope` handling is already in place
- we can animate on connected mount with LiveView-aware transitions

### New Modules

Create:

- `lib/assistant_web/live/marketing_live.ex`
- optionally `lib/assistant_web/components/marketing_page.ex`

Why split:

- LiveView owns assigns and route state
- component module owns the large HEEx section tree

### CSS Strategy

Add a new namespaced block to `assets/css/app.css`:

- `sa-marketing-*`

Do not overload settings-page classes for unique landing page layout behavior.

Reuse existing primitives where possible:

- `sa-btn`
- `sa-card`
- `sa-chip`
- brand variables from `:root`

### JS Strategy

Add hooks to `priv/static/assets/app.js`:

- `Hooks.MarketingParallax`
- `Hooks.MarketingReveal`
- `Hooks.MarketingStickyScene`
- `Hooks.MarketingNav`

These hooks should match the current style of the existing hooks file:

- small, explicit objects
- no framework inside the framework
- direct DOM reads and writes

## Official Guidance To Apply

### LiveView Transitions

Use `phx-mounted` with `Phoenix.LiveView.JS.transition/2` for initial entry animations where the effect is simple and mount-scoped.

Why:

- LiveView’s official bindings docs explicitly support `phx-mounted`
- `Phoenix.LiveView.JS` transitions are DOM-patch aware

Good uses:

- hero headline fade/slide in
- CTA stagger
- pricing card entrance
- capability card icon and body reveal

### Hooks For Scroll Effects

Use `phx-hook` for:

- parallax
- intersection-based reveal
- sticky scene state changes

Why:

- official LiveView docs say updated DOM reactions should use hooks
- hooks provide `mounted`, `updated`, `destroyed`, `disconnected`, `reconnected`

### `phx-update="ignore"` For Client-Controlled Visual Islands

Use `phx-update="ignore"` on purely client-driven visual wrappers when needed.

Examples:

- parallax canvas / decorative layer
- scene wrapper if the client mutates child transforms directly

Important:

- give the container a stable DOM id
- only use `ignore` where the client truly owns that DOM subtree

### Browser Performance

From MDN guidance:

- use `IntersectionObserver` for reveal detection rather than heavy scroll polling
- use `requestAnimationFrame()` for scroll-linked parallax updates
- use `content-visibility: auto` on lower page sections to reduce initial render cost
- honor `@media (prefers-reduced-motion: reduce)`

## Motion + Performance Guardrails

### Do

- animate `transform` and `opacity`
- keep one global scroll listener max
- fan out visual updates with CSS variables
- throttle updates through `requestAnimationFrame`
- use `IntersectionObserver` for section activation

### Do Not

- mutate layout-heavy properties every frame
- attach a separate scroll listener for each section
- use a canvas or WebGL scene unless the DOM version clearly fails
- make scroll behavior depend on server round-trips

## Accessibility

The page must still work without motion.

Rules:

- preserve full content in source order
- reduced motion mode disables parallax and large scene drift
- sticky scene must degrade to stacked content on narrow screens
- all CTAs remain visible without scroll effects
- contrast must stay strong on gradient backgrounds

## Responsive Behavior

### Desktop

- hero is two-column
- sticky scene is side-by-side
- pricing is two-up

### Tablet

- hero keeps the single-banner composition but compresses the scene depth
- sticky scene compresses spacing
- connector marquee reduces speed and logo spacing

### Mobile

- hero remains one banner with the product scene stacked below the copy
- sticky scene becomes stacked step cards
- motion simplifies to subtle fade and tiny translate
- no giant parallax drift
- connector marquee can downgrade to a wrapped logo grid if motion feels too busy

## Proposed Implementation Phases

### Phase 1: Structure

1. Add route at `/cloud`.
2. Add `MarketingLive`.
3. Render the page with all major sections and real copy.
4. Add only static responsive layout and core styling.

### Phase 2: Visual Polish

1. Add hero backgrounds and orbit layers.
2. Refine card surfaces and spacing.
3. Add product mock panels and connector marquee.

### Phase 3: Motion

1. Add `phx-mounted` entry transitions.
2. Add reveal hook with `IntersectionObserver`.
3. Add hero parallax hook with `requestAnimationFrame`.
4. Add sticky story scene activation.
5. Add connector marquee animation.

### Phase 4: Hardening

1. Add reduced-motion behavior.
2. Add `content-visibility: auto` to late sections.
3. Tune mobile fallback.
4. Verify performance and scroll smoothness.

## File Plan

### Files To Create

- `lib/assistant_web/live/marketing_live.ex`
- `lib/assistant_web/components/marketing_page.ex`

### Files To Modify

- `lib/assistant_web/router.ex`
- `assets/css/app.css`
- `priv/static/assets/app.js`

## Copy Direction

### Hero Headline Options

Option A:

> Your workspace, synced across tools. Your models. Our orchestration.

Option B:

> Connect the tools you already use. Keep the intelligence you already pay for.

Option C:

> Synced context, durable memory, safe automation.

Preferred:

- Option A

### Supporting Copy

Suggested:

> Synaptic Assistant Cloud turns connected documents, conversations, and workflows into a shared working memory. Bring your own model access. We handle sync, storage, approvals, and orchestration.

### Pricing Microcopy

Suggested:

> 25 MB free. Pro is $18 per user per month with 10 GB included. Storage above 10 GB is billed at $1 per GB-month based on monthly average usage.

### Enterprise Microcopy

Suggested:

> Enterprise includes custom storage limits, admin controls, and commercial support. Contact us for pricing.

## References

Official / primary references used for this plan:

- Phoenix LiveView bindings:
  - [https://hexdocs.pm/phoenix_live_view/1.1.7/bindings.html](https://hexdocs.pm/phoenix_live_view/1.1.7/bindings.html)
- Phoenix LiveView JS commands:
  - [https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.JS.html](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.JS.html)
- Phoenix LiveView JS interoperability:
  - [https://hexdocs.pm/phoenix_live_view/1.1.1/js-interop.html](https://hexdocs.pm/phoenix_live_view/1.1.1/js-interop.html)
- MDN `IntersectionObserver`:
  - [https://developer.mozilla.org/en-US/docs/Web/API/Intersection_Observer_API](https://developer.mozilla.org/en-US/docs/Web/API/Intersection_Observer_API)
- MDN `requestAnimationFrame()`:
  - [https://developer.mozilla.org/en-US/docs/Web/API/Window/requestAnimationFrame](https://developer.mozilla.org/en-US/docs/Web/API/Window/requestAnimationFrame)
- MDN `prefers-reduced-motion`:
  - [https://developer.mozilla.org/docs/Web/CSS/%40media/prefers-reduced-motion](https://developer.mozilla.org/docs/Web/CSS/%40media/prefers-reduced-motion)
- MDN `content-visibility`:
  - [https://developer.mozilla.org/en-US/docs/Web/CSS/content-visibility](https://developer.mozilla.org/en-US/docs/Web/CSS/content-visibility)
- MDN `scroll-snap-type`:
  - [https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Properties/scroll-snap-type](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Properties/scroll-snap-type)

## Recommendation

Build the page as a LiveView at `/cloud` first.

That keeps routing low-risk, preserves auth behavior, and gives us a clean place to refine the public product narrative before deciding whether the marketing page should eventually take over `/`.

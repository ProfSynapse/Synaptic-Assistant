# Google Chat API: Email and Space Type Availability Verification

> Prepared for identity-bridge-fix feature — verifying two critical assumptions before implementation.

## Executive Summary

Both assumptions are **confirmed viable** with important nuances:

1. **User email**: Available in Google Chat interaction event payloads via `user.email` (and `chat.user.email` in v2 format). The existing `google_chat.ex` normalizer already extracts this field. No additional scopes required beyond standard Chat app configuration.

2. **Space type**: Available via `space.type` in interaction events. The existing normalizer already stores this in `metadata["space_type"]`. Three values: `"SPACE"`, `"GROUP_CHAT"`, `"DIRECT_MESSAGE"`. Sufficient for filtering DM spaces from passive context injection.

---

## 1. User Email Availability

### Finding: CONFIRMED

The Google Chat API includes the `email` field in the `User` object within interaction event payloads (both v1 and v2 formats).

**Official documentation example** (from [Identify and specify Google Chat users](https://developers.google.com/workspace/chat/identify-reference-users)):

```json
{
  "user": {
    "name": "users/12345678901234567890",
    "displayName": "Sasha",
    "avatarUrl": "https://lh3.googleusercontent.com/.../photo.jpg",
    "email": "sasha@example.com"
  }
}
```

### Important Distinction: Interaction Events vs REST API

The `email` field is present in **interaction event payloads** (the JSON your Chat app receives when users send messages), but it is **NOT** a formal field on the REST API `User` resource model.

- **REST API `User` resource** ([API reference](https://developers.google.com/workspace/chat/api/reference/rest/v1/User)): Only has `name`, `displayName`, `domainId`, `type`, `isAnonymous` — no `email` field.
- **Java SDK `User` class** (v1-rev20260205-2.0.0): Confirms no `getEmail()`/`setEmail()` methods.
- **Interaction event payload**: Includes `email` as an additional field populated by the platform.

This means: email is available in the webhook payloads we receive, but if you ever need to look up a user via the REST API, you would NOT get their email back. For our identity bridge use case (matching webhook sender to settings_user), this is fine — we only need the email from the incoming event.

### Existing Normalizer Already Extracts Email

The `google_chat.ex` normalizer (lines 198, 238, 268, 301) already extracts `user["email"]` and stores it as `user_email` on the `%Message{}` struct:

**v2 format** (lines 182, 198):
```elixir
user = chat["user"] || message["sender"] || %{}
# ...
user_email: user["email"],
```

**v1 format** (lines 285, 301):
```elixir
user = event["user"] || message["sender"] || %{}
# ...
user_email: user["email"],
```

The `%Message{}` struct (line 28) has `user_email: String.t() | nil` as a typed field.

The Dispatcher (lines 132, 245) passes `user_email: message.user_email` to `UserResolver.resolve/3`.

### Scope Requirements

No additional OAuth scopes are needed. The email is populated automatically in interaction event payloads for Google Workspace users. The standard Chat app scopes (`https://www.googleapis.com/auth/chat.bot` or the Workspace Add-on scope) are sufficient.

### Edge Cases and Caveats

| Scenario | Email Available? | Notes |
|----------|-----------------|-------|
| Google Workspace user | Yes | Standard case — email populated |
| Consumer Google account | Likely yes | Gmail address used |
| External guest users | Unclear | May depend on org settings |
| Bot/app interactions | No | `type: "BOT"` — no email |
| Anonymous users | No | `isAnonymous: true` — no email |

**Recommendation**: Always treat `user_email` as nullable. The identity bridge should have a fallback path when email is nil (manual admin linking via the settings dashboard).

---

## 2. DM Space Detection (Space Type)

### Finding: CONFIRMED

The Google Chat API `Space` resource includes a `spaceType` field (and a deprecated `type` field) in both interaction events and REST API responses.

**Enum values** (from [REST Resource: spaces](https://developers.google.com/workspace/chat/api/reference/rest/v1/spaces)):

| `spaceType` Value | Description |
|-------------------|-------------|
| `SPACE_TYPE_UNSPECIFIED` | Reserved / default |
| `SPACE` | Named space — people send messages, share files, collaborate |
| `GROUP_CHAT` | Group conversation between 3+ people |
| `DIRECT_MESSAGE` | 1:1 messages between two humans or human + Chat app |

**Deprecated `type` field** (still present in payloads):

| `type` Value | Maps To |
|-------------|---------|
| `TYPE_UNSPECIFIED` | `SPACE_TYPE_UNSPECIFIED` |
| `ROOM` | `SPACE` |
| `DM` | `DIRECT_MESSAGE` |

### Field Path in Payloads

**v1 format**: `event["space"]["type"]`
**v2 format**: `payload["space"]["type"]` (within `messagePayload`, `addedToSpacePayload`, etc.)

Note: In the interaction event payloads, the field is `"type"` on the space object, not `"spaceType"`. The `"spaceType"` field name is used in the REST API resource representation. The existing normalizer uses `space["type"]` which is correct.

### Existing Normalizer Already Extracts Space Type

The `google_chat.ex` normalizer stores the space type in message metadata:

**v2 message** (line 205):
```elixir
"space_type" => space["type"],
```

**v1 message** (line 307):
```elixir
"space_type" => space["type"],
```

This means `message.metadata["space_type"]` is already available for DM filtering.

### Values for DM Detection

For the passive context injection feature, filter logic should check:

```elixir
# Skip DM spaces — only fan out in shared spaces
case message.metadata["space_type"] do
  "DM" -> :skip           # v1 format DM
  "DIRECT_MESSAGE" -> :skip  # v2 format / REST API format
  _ -> :fan_out           # SPACE, GROUP_CHAT, ROOM, etc.
end
```

**Both `"DM"` and `"DIRECT_MESSAGE"` should be checked** because:
- v1 events may use `"DM"` (the deprecated `type` enum)
- v2 events and newer payloads may use `"DIRECT_MESSAGE"` (the current `spaceType` enum)

In practice, the `space["type"]` field in interaction event payloads typically uses the deprecated values (`"DM"`, `"ROOM"`), but defensive coding should handle both.

---

## 3. Existing Data Flow Summary

```
Webhook payload
  ├── v1: event["user"]["email"]       → message.user_email
  ├── v2: chat["user"]["email"]        → message.user_email
  ├── v1: event["space"]["type"]       → message.metadata["space_type"]
  └── v2: payload["space"]["type"]     → message.metadata["space_type"]
          ↓
Dispatcher.dispatch/2
  └── UserResolver.resolve(:google_chat, user_id, %{user_email: ...})
          ↓
Identity bridge: match user_email → settings_users.email → settings_users.user_id
```

Both fields are already normalized and threaded through the dispatch pipeline. The identity bridge implementation can consume them directly without any normalizer changes.

---

## 4. Recommendations for Implementation

1. **Email matching**: Use `message.user_email` (already available) to match against `settings_users.email` for auto-linking. Handle nil gracefully — not all users will have email in the payload.

2. **DM filtering**: Use `message.metadata["space_type"]` to detect DMs. Check for both `"DM"` and `"DIRECT_MESSAGE"` values.

3. **No normalizer changes needed**: The existing `google_chat.ex` normalizer already extracts both fields correctly.

4. **No additional scopes needed**: Email is included in standard interaction event payloads.

---

## Sources

- [Identify and specify Google Chat users](https://developers.google.com/workspace/chat/identify-reference-users) — User identity structure with email example
- [REST Resource: spaces](https://developers.google.com/workspace/chat/api/reference/rest/v1/spaces) — Space resource with spaceType enum
- [User resource](https://developers.google.com/workspace/chat/api/reference/rest/v1/User) — REST API User model (no email field)
- [Event resource](https://developers.google.com/workspace/chat/api/reference/rest/v1/Event) — Interaction event structure
- [Types of Chat app interaction events](https://developers.google.com/workspace/chat/interaction-events) — Event type reference
- [Receive and respond to interaction events](https://developers.google.com/workspace/chat/receive-respond-interactions) — Event handling overview

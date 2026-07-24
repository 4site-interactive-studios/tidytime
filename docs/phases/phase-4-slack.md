# Phase 4 — Slack

Stand up the internal Slack app from a bundled manifest, guide the one-time install, and ingest
DMs/channels on a poll into `slack_messages` — then group that activity into `kind='slack'`
sessions so a morning of Slack (including messages you sent from your phone) appears on the
timeline, attributed to the right conversations and ready to seed micro-work pools.

**Related:** [doc index](../README.md) · [PLAN.md](../../PLAN.md) §5, §11 ·
[reference/slack-api.md](../reference/slack-api.md) ·
[permissions-setup.md](../permissions-setup.md) ·
[architecture/ingest-layer.md](../architecture/ingest-layer.md) ·
[phase-3-meetings-calendar.md](phase-3-meetings-calendar.md) ·
[phase-5-recap-rules.md](phase-5-recap-rules.md)

**Phase:** 4 of 6 · **Target:** `TidyIngest` (+ a declared early slice of `TidyUnderstand`) ·
**Depends on:** Phases 0–3 (store, capture, Productive mirror, meetings/calendar) ·
**Unlocks:** Phase 5 pools & recap have Slack micro-work to work with ·
**Status:** build-ready spec · **Last verified:** 2026-07-23

---

## 0. At a glance

| | |
|---|---|
| **Ships** | Bundled Slack app manifest; guided self-serve install; `LiveSlackClient` (read-method allowlist); two-tier polling (`SlackConversationsSource` + `SlackHistorySource`) → `slack_messages`; `SlackSessionizer` → `kind='slack'` sessions on the timeline |
| **New table** | `slack_messages` — created by **this phase's own migration** (`v1-slack`), matching the [data-model.md](../architecture/data-model.md) phase map, which places `slack_messages` under Phase 4. Register it with the same one-migration-per-phase pattern as Phases 2/3/5/6. |
| **New `sync_state` rows** | `slack:conversations` (list marker) + one `slack:<conversation_id>` per readable conversation |
| **Reads** | Slack Web API, **read-only** scopes only; `xoxp-…` user token from Keychain |
| **Does NOT ship** | client/project **attribution** of Slack (rungs 1–2 = Phase 5); the `pools` table & accumulator (Phase 5); the recap window (Phase 5); Events API / Socket Mode (post-v1) |
| **Endpoints & JSON** | live in [reference/slack-api.md](../reference/slack-api.md) — this doc does **not** restate them; it sequences the build |

### Acceptance criteria (PLAN §11, human-verifiable)

> **A morning of Slack activity shows up attributed to the right conversations, including
> messages sent from your phone.**

Concretely, after this phase the `doctor` timeline view for a given morning shows:

- [ ] Each active DM / channel / group-DM you touched appears as a `kind='slack'` session with the
      correct `conversation_name` and `conversation_type` (`im` / `channel` / `group` / `mpim`).
- [ ] Messages **you authored from your phone** (never seen by screen capture) are present with
      `is_self = 1` — this is the headline proof that API ingest beats screen-watching.
- [ ] Threaded replies are captured and grouped under their root (`thread_ts`), not lost.
- [ ] Re-running the sync writes **zero** new rows (idempotent; `UNIQUE(conversation_id, ts)`).
- [ ] The Slack token lives only in the Keychain; it appears in no log, config file, or fixture.
- [ ] Slack sessions merge into the same timeline as screen sessions and meetings, ordered by
      `started_at`, and remain **unclassified** (`client_id` NULL) — attribution is Phase 5.

Attribution here means *the right conversation*, not yet *the right client*. Client attribution
of these sessions is Phase 5's job ([understand-layer.md](../architecture/understand-layer.md)).

---

## 1. Prerequisites

Before writing code:

1. **Phases 0–3 landed.** `TidyStore` (incl. the `sync_state` DDL from Phase 1; `slack_messages` is created by this phase's `v1-slack` migration),
   `TidyCore` (`SecretStore`, `Clock`, `TidyLog`), and the `TidyIngest` scaffolding
   (`IngestSource`, `IngestCoordinator`, `HTTPClient`, `RateLimiter`, `Backoff`) already exist —
   Slack plugs into them (see [ingest-layer.md](../architecture/ingest-layer.md) §3, §5).
2. **Workspace admin.** The user is a 4Site workspace admin, so app creation, scope approval, and
   install are **self-serve** — no Slack Marketplace review (PLAN §5, §10.8).
3. **Read [reference/slack-api.md](../reference/slack-api.md) end-to-end.** Every endpoint, param,
   response shape, the `ts`↔epoch rule, permalink construction, and the 2025 rate-limit exemption
   live there. This phase doc references sections of it rather than duplicating them.
4. **Confirm the internal-app rate-limit exemption is still in force** (⚠️ Build-time check —
   slack-api.md §7, PLAN §14.3): re-read the May-29-2025 changelog + rate-limits page. If it has
   tightened, fall back to the mitigations in §7 there (stretch cadence, `limit=15`, Events API).

---

## 2. The bundled manifest & guided install

The app ships a **Slack app manifest** (YAML/JSON) as a bundled resource; the setup flow walks the
user through creating the app from it, installing it, and pasting the resulting user token. Target
~10 minutes, self-serve. The manifest content and the click-path live in
[permissions-setup.md](../permissions-setup.md); this section states what Phase 4 must build.

### 2.1 What the manifest declares

- **App name / description:** identifies it as the user's personal TidyTime ingest app.
- **`oauth_config.scopes.user`** — the exact read-only user-token scopes from
  [slack-api.md §2](../reference/slack-api.md#2-scopes-user-token):
  `channels:read`, `channels:history`, `groups:read`, `groups:history`, `im:read`, `im:history`,
  `mpim:read`, `mpim:history`, `users:read`, `users:read.email`.
- **No bot scopes, no `chat:write`, no event subscriptions, no interactivity** — v1 is poll-only
  and read-only. A write scope that does not exist cannot be called (G1-style architectural
  enforcement; see [ingest-layer.md §2](../architecture/ingest-layer.md#2-the-read-only-invariant-g1-is-architectural-not-incidental)).

> ⚠️ Build-time check (PLAN §14.3): the Slack **manifest editor validates scope names** at create
> time. Confirm the list above against the editor; a missing `*:history` scope surfaces later as
> `{"ok":false,"error":"missing_scope","needed":"…"}`. Keep the bundled manifest and
> [slack-api.md §2](../reference/slack-api.md#2-scopes-user-token) in sync if the list changes.

### 2.2 Guided-install flow (setup UI)

The Settings/onboarding surface presents an ordered, resumable checklist:

1. **Create app from manifest** — deep link to `https://api.slack.com/apps?new_app=1` with a
   "copy manifest" button (copies the bundled manifest to the clipboard) and step text.
2. **Install to 4Site workspace** — the user clicks *Install to Workspace* and approves the scopes
   (self-serve as admin).
3. **Copy the User OAuth Token** (`xoxp-…`) from *OAuth & Permissions* and paste it into the app.
4. **Store & verify** — the app writes the token to the **Keychain** via `SecretStore` (never to
   `config.json`; G6) and immediately calls `auth.test` to confirm the token and resolve the
   user's own `user_id` (needed for `is_self`).

```swift
// TidyIngest/Slack/SlackSetup.swift — verify a freshly pasted token, persist to Keychain.
func verifyAndStore(userToken raw: String, secrets: SecretStore,
                    client: SlackClient) async throws -> SlackIdentity {
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard token.hasPrefix("xoxp-") else { throw IngestError.setup("Expected a user token (xoxp-…)") }
    let id = try await client.authTest(token: token)          // GET-style read; see slack-api.md §4.1
    try secrets.set(token, for: .slackUserToken)              // Keychain only (G6)
    // id.userId → cached for the sync run; id.url → permalink host fallback.
    return id
}
```

- On `invalid_auth` / `token_revoked`, do **not** store; show the error and let the user re-paste.
- `doctor` surfaces Slack auth status (present / verified / re-auth needed) so a revoked token is
  **visible**, not a silent capture gap ([ingest-layer.md §6](../architecture/ingest-layer.md#6-rate-limits--exponential-backoff)).
- The manifest install is a one-time human step; capture the exact screenshots/click-path in
  [permissions-setup.md](../permissions-setup.md).

---

## 3. The read-only Slack client (`LiveSlackClient`)

Slack's Web API is `POST`/query-based even for reads, so "GET-only" is not the guardrail here.
Instead, per [ingest-layer.md §2](../architecture/ingest-layer.md#2-the-read-only-invariant-g1-is-architectural-not-incidental),
`LiveSlackClient` enforces read-only two ways:

1. **Scope-level:** the installed token carries only `*:read` / `*:history` / `users:read[.email]`
   scopes — no write scope exists to invoke.
2. **Method allowlist:** the client can only ever send a compile-time allowlist of read methods.
   A guardrail test asserts no method string outside the allowlist reaches the transport.

```swift
// TidyIngest/Slack/SlackClient.swift
protocol SlackClient: Sendable {
    func authTest(token: String) async throws -> SlackIdentity
    func conversationsList(cursor: String?) async throws -> ConversationsPage
    func conversationsHistory(channel: String, oldest: String?, cursor: String?)
        async throws -> HistoryPage
    func conversationsReplies(channel: String, ts: String, cursor: String?)
        async throws -> HistoryPage
    func usersList(cursor: String?) async throws -> UsersPage
    func usersInfo(user: String) async throws -> SlackUser
    func chatGetPermalink(channel: String, messageTs: String) async throws -> String
}

enum SlackMethod: String, CaseIterable {          // the ONLY strings that reach the transport
    case authTest            = "auth.test"
    case conversationsList   = "conversations.list"
    case conversationsHistory = "conversations.history"
    case conversationsReplies = "conversations.replies"
    case usersList           = "users.list"
    case usersInfo           = "users.info"
    case chatGetPermalink    = "chat.getPermalink"
}
// Guardrail test: assert LiveSlackClient never issues a method outside SlackMethod.allCases,
// and in particular never chat.postMessage / reactions.add / any write.
```

- **Transport & errors:** every response is HTTP `200` except `429`; branch on the JSON body's
  `ok` field, not the HTTP status (slack-api.md §3). Redact `Authorization` on any logged request
  (G6).
- **Rate limits:** honor `Retry-After` **exactly** on `429`; never advance a cursor on a
  non-success (slack-api.md §7.1, ingest-layer.md §6). The internal-app exemption keeps
  `conversations.history`/`replies` at ~50+/min, 1,000 objects — plain polling is viable.

---

## 4. Two-tier polling → `slack_messages`

Slack is the one provider that shards into many `sync_state` rows. The mechanics (cursor
semantics, paging, field mapping, upsert SQL, `ts`↔epoch, permalinks) are specified in
[slack-api.md §4–§6](../reference/slack-api.md#4-endpoints-used) and
[ingest-layer.md §5.1, §7.3](../architecture/ingest-layer.md#51-slacks-two-tier-scheduling). Build:

### 4.1 `SlackConversationsSource` (`slack:conversations`, ~5 min)

- Calls `conversations.list` with `types=public_channel,private_channel,mpim,im`,
  `exclude_archived=true`, paging `next_cursor`.
- Maps each conversation's booleans to `conversation_type` and resolves its display name
  (peer `real_name` for `im`) per [slack-api.md §4.2](../reference/slack-api.md#42-conversationslist--what-to-sync).
- Reads each conversation's `latest.ts`; a conversation whose `latest.ts` exceeds its stored
  `slack:<id>` cursor is marked **active** for this cycle.
- Filters public channels to `is_member == true`; treats all `im`/`mpim`/private as readable.
- Cadence from `config.ingest.slack.conversation_list_interval_seconds` (default **300**).

### 4.2 `SlackHistorySource` (per active conversation, ~3 min)

For each **active** conversation only (inactive ones cost zero history calls):

1. `oldest = sync_state["slack:<id>"].cursor` (last max `ts`, or unset on first run).
2. Page `conversations.history(channel, oldest, limit=200)` via `next_cursor`.
3. For each thread root (`reply_count > 0` or `thread_ts == ts`), page
   `conversations.replies(channel, ts)` — history does **not** inline replies.
4. **Skip non-conversational rows** (`subtype` = `channel_join`/`channel_leave`/bot-without-`user`,
   `message_deleted`, etc.); keep plain `type:"message"` rows.
5. UPSERT each kept message on `UNIQUE(conversation_id, ts)`; advance the cursor to `max(ts)` **in
   the same transaction** (ingest-layer.md §7.3, §7.4). Advance only on success.
6. Cadence from `config.ingest.slack.history_interval_seconds` (default **180**).

### 4.3 Names/emails and `is_self`

- Bootstrap an in-memory `[user_id: (name, email)]` cache via `users.list`; fill misses with
  `users.info`. There is **no** Slack users table — names denormalize onto
  `slack_messages.user_name` at ingest ([slack-api.md §4.5](../reference/slack-api.md#45-userslist--usersinfo--names--emails)).
- Set `slack_messages.is_self = 1` when `message.user == auth.test.user_id`. **This is what makes
  phone-sent messages attributable** — they arrive in history like any other message; there is no
  device-origin flag, so authorship (`is_self`) is the signal (slack-api.md §4.1, §6).
- `profile.email` yields an `email_domain` — Phase 5 feeds it to `entity_signals`
  (`person_email` / `email_domain`) for client attribution. Phase 4 only stores the message; it
  does **not** mint signals.

### 4.4 Field mapping (verbatim target)

Map to `slack_messages` exactly as in [slack-api.md §6](../reference/slack-api.md#6-field-mapping--slack_messages)
and [data-model.md](../architecture/data-model.md#slack-phase-4). Non-negotiable details:

- **Keep `ts` as the original string** (`"1721739600.001500"`) — it is the uniqueness key and the
  `oldest`/`replies` param; never round-trip it through a `Double` (precision loss breaks the key).
- **Derive `posted_at`** = floored integer seconds of `ts`, for ordering/indexing only.
- **Permalinks:** prefer zero-call **construction** from `auth.test.url` + channel + `ts`; reserve
  `chat.getPermalink` for messages the recap actually surfaces (slack-api.md §6.4).

---

## 5. Slack sessions on the timeline (`SlackSessionizer`)

This is the deliverable behind "Slack sessions merged into the timeline." Per
[understand-layer.md §1.3](../architecture/understand-layer.md#13-meeting--slack-sessions-from-ingest-not-screen-samples),
a Slack session is `slack_messages` grouped by `conversation_id`.

### 5.1 What Phase 4 builds

- Group a day's `slack_messages` by `conversation_id`; a burst of activity on one conversation
  (self-authored plus surrounding context) becomes **one** `sessions` row with:

  | `sessions` column | Value |
  |---|---|
  | `kind` | `'slack'` |
  | `source_ref` | `conversation_id` |
  | `context_key` | `conversation_id` (normalized) — Phase 5's rung 1 keys `slack_channel` signals off this |
  | `title` | `conversation_name` |
  | `started_at` / `ended_at` | first / last `posted_at` in the burst |
  | `duration_seconds` | `ended_at − started_at` (see §5.2 gotcha) |
  | `client_id` / `project_id` / `task_id` / `confidence` / `produced_by_rung` / `rationale` | **NULL** — classification is Phase 5 |
  | `is_sensitive` | `0` (the sensitivity gate lands in Phase 6, G2; no cloud call happens here) |

- Sessions land in the **same** `sessions` table as screen (Phase 1) and meeting (Phase 3)
  sessions and merge into one timeline ordered by `started_at`.

### 5.2 Burst grouping (config-driven, mirrors screen sessionization)

Break a conversation's messages into sessions on a quiet-gap boundary so an hour-long back-and-forth
is one session but a morning DM and an afternoon DM on the same conversation are two:

- Start a new burst when the gap between consecutive `posted_at` values in a conversation exceeds
  `config.sessionization.detour_tolerance_seconds` (default **120**) scaled for chat — reuse the
  same knob; a longer idle-gap constant can be added later if chat proves too chatty.
- Drop bursts shorter than `config.sessionization.min_session_seconds` (default **60**) **unless**
  they contain an `is_self` message — a single one-line answer you typed is exactly the billable
  drive-by we must not discard (fold it to a minimum-duration session rather than dropping).

> **Gotcha — zero-duration bursts.** A lone message has `started_at == ended_at`, so
> `duration_seconds = 0`. Floor a self-authored single-message burst to a small minimum (a
> `config.sessionization.min_session_seconds`-bounded value) so it survives to seed a pool in
> Phase 5; a message you only *received* with no reply can stay 0 and be filtered as noise.

### 5.3 Where this code lives (phase-boundary note)

The full `Sessionizer` (screen sessions + rungs 1–2 classification) is a **Phase 5** deliverable in
`TidyUnderstand` ([module-map.md](../architecture/module-map.md)). `SlackSessionizer` is the **one
declared early slice** that ships in Phase 4 because PLAN §11 puts "Slack sessions merged into the
timeline" here. Implement it as a small, self-contained unit (it may live in a Phase-4 file within
`TidyUnderstand`, or as a store-side grouping query surfaced to the `doctor` timeline) that:

- reads only `slack_messages` (no capture/AI dependency),
- writes only `kind='slack'` `sessions` rows with attribution columns left NULL,
- is **superseded** in Phase 5 by the general classifier that fills in `client_id` etc.

Keep it minimal; do not pull Phase-5 classification forward (repo rule: no cross-phase work unless
a phase doc declares the seam — this is that declaration).

---

## 6. Pool seeding for drive-by help (what Phase 4 does vs. defers)

PLAN §11 lists "pool seeding for drive-by help" under Phase 4, while the `pools` **table** and the
pooling accumulator are **Phase 5** deliverables ([data-model.md](../architecture/data-model.md)
phase map; [suggestion-engine.md](../architecture/suggestion-engine.md)). Reconciliation:

- **Phase 4 produces the raw material.** The sub-threshold `kind='slack'` sessions from §5 — the
  three-message answer to Nick, the quick staging-link review — are exactly the micro-work that
  Phase 5 rolls up into a pool. Phase 4's job is to make sure those sessions **exist, are grouped
  by the right conversation, and carry a self-authored signal** so pooling has something to gather.
- **Phase 4 does NOT create `pools` or accumulate them.** No `pools` rows are written this phase;
  no `suggestions` are emitted.
- **Verify the seam** in the Phase-4 acceptance by confirming the sub-threshold slack sessions are
  present and conversation-attributed; Phase 5's acceptance then confirms they pool into a
  rolled-up suggestion (PLAN §8 micro-work pools).

This is a deliberate phase-boundary split; see `uncertainties` in the build notes.

---

## 7. File & function manifest (`TidyIngest`, + one `TidyUnderstand` slice)

Under `Packages/TidyKit/Sources/`. Regenerate the Xcode project with `make generate` after adding
files (XcodeGen reads the folder tree).

| File | Contents |
|---|---|
| `TidyIngest/Slack/SlackClient.swift` | `SlackClient` protocol; `SlackMethod` allowlist enum; DTOs (`SlackIdentity`, `ConversationsPage`, `HistoryPage`, `UsersPage`, `SlackUser`) |
| `TidyIngest/Slack/LiveSlackClient.swift` | real `URLSession` impl; `Authorization: Bearer` from Keychain; `ok`-field error branching; `429`/`Retry-After` handling |
| `TidyIngest/Slack/SlackSetup.swift` | `verifyAndStore(userToken:)`, `auth.test` round-trip, Keychain write, `doctor` status |
| `TidyIngest/Slack/SlackConversationsSource.swift` | `IngestSource` for `slack:conversations`; list + activity scan; marks active conversations (§4.1) |
| `TidyIngest/Slack/SlackHistorySource.swift` | `IngestSource` for active `slack:<id>`; history + replies paging; UPSERT + transactional cursor advance (§4.2) |
| `TidyIngest/Slack/SlackUserCache.swift` | in-memory `[user_id:(name,email)]`; `users.list` bootstrap + `users.info` fill (§4.3) |
| `TidyIngest/Mapping/SlackMapping.swift` | DTO → `SlackMessage` record: `conversation_type` mapping, `posted_at` from `ts`, `is_self`, permalink construction (§4.4) |
| `TidyUnderstand/SlackSessionizer.swift` | **declared early slice** — group `slack_messages` → `kind='slack'` sessions (§5); attribution columns NULL |
| `App/Setup/SlackInstallView.swift` | guided-install checklist UI (copy manifest, paste token, verify) — thin shell over `SlackSetup` |
| bundled resource: `Resources/slack-app-manifest.json` | the app manifest (scopes from §2.1) |

**Tests** (`Packages/TidyKit/Tests/TidyIngestTests/` + `…/TidyUnderstandTests/`) — see §9.

Depends on: `TidyCore` (`SecretStore`, `Clock`, `TidyLog`, models), `TidyStore` (DAOs, records,
`sync_state`), and the existing `IngestSource`/`IngestCoordinator`/`HTTPClient` scaffolding. No
dependency on `TidyCapture` or `TidyAI` (module-map rule).

---

## 8. Config additions

Phase 4 uses config keys that already exist in `config.example.json` — **do not invent new ones**:

```json
{
  "capture": { "kill_switches": { "slack": true } },
  "ingest": {
    "slack": {
      "conversation_list_interval_seconds": 300,
      "history_interval_seconds": 180
    }
  },
  "retention_days": { "slack_messages": 90 }
}
```

- `capture.kill_switches.slack` — when `false`, the coordinator does not register the Slack sources
  (PLAN §9 kill switches; ingest-layer.md §5).
- The two `ingest.slack.*` intervals drive the two-tier cadence (§4).
- `retention_days.slack_messages` (default 90) — the retention job (Phase 1) purges raw Slack rows
  after the window; derived `sessions` persist (G9, §10).

No secret goes in config — the `xoxp-…` token is Keychain-only (G6).

---

## 9. Testing (fixtures, no live network)

Per [module-map.md §Testability](../architecture/module-map.md#testability) and
[slack-api.md §9](../reference/slack-api.md#9-testing-fixtures-no-live-network), the Slack client
sits behind the `SlackClient` protocol and is tested with **recorded fixtures** (token stripped)
under `Tests/TidyIngestTests/Fixtures/slack/`. Capture one real response per method:
`auth.test`, `conversations.list` (all four kinds), `conversations.history` (with a threaded root),
`conversations.replies`, `users.info`, plus a `429`.

Assert:

- [ ] **Conversation-type mapping** across `im` / `channel` / `group` / `mpim` (slack-api.md §4.2).
- [ ] **`ts` preserved verbatim**; `posted_at` correctly floored (slack-api.md §6.3).
- [ ] **`is_self`** set exactly when `user == auth.test.user_id` (proves phone-sent authorship).
- [ ] **Thread replies** upsert without duplicating the repeated root (unique index).
- [ ] A **subtype row** (`channel_join`) and a `message_deleted` are skipped.
- [ ] **Idempotency:** a second `sync()` with unchanged fixtures writes 0 rows and does not move the
      cursor; a thrown fetch leaves cursor + data unchanged and populates `sync_state.last_error`.
- [ ] **`429`** drives one `Retry-After` backoff and recovers next tick without a duplicate-key
      crash; the cursor never advances on non-success.
- [ ] **Read-only guardrail:** `LiveSlackClient` never issues a method outside `SlackMethod`; no
      `chat.postMessage`/reaction/write is reachable (ingest-layer.md §2, §8).
- [ ] **G6:** no committed fixture and no log line contains a token or `Authorization` header.
- [ ] **`SlackSessionizer`:** a burst of messages on one conversation collapses to one
      `kind='slack'` session with the right `conversation_name`, `source_ref`, and time bounds; a
      lone self-authored message survives to a minimum-duration session; attribution columns are
      NULL.

All run with fixtures + in-memory GRDB (`make test`).

---

## 10. Guardrails that bind this phase

| Guardrail | How Phase 4 satisfies it |
|---|---|
| **G1** (read-only Productive) | N/A to Slack directly; the Slack client is likewise read-only — scopes are all `:read`/`:history`, and the method allowlist blocks any write (§3, ingest-layer.md §2). |
| **G2** (sensitivity gate) | Slack `text` is high-risk (personnel/comp/legal in DMs). Phase 4 **stores it locally only** and sends nothing to any cloud model — no cloud path exists yet. The gate becomes load-bearing in Phase 6 before Slack text ever enters a cloud payload (slack-api.md §8). Sessions ship `is_sensitive = 0` this phase. |
| **G6** (secrets in Keychain) | The `xoxp-…` token is written via `SecretStore` only; redacted in logs and the outbound-payload log; absent from `config.json` and fixtures (§2.2, §8). |
| **G8** (one process) | Slack sources are `async` Tasks in the single menu-bar process, driven by `IngestCoordinator` — no daemon, no helper (ingest-layer.md §5). |
| **G9** (retention) | `slack_messages` is raw/sensitive → purges after `retention_days.slack_messages` (default 90); the forward-only cursor means purged rows are **not** re-imported (ingest-layer.md §10). Derived `sessions` persist. |

---

## 11. Gotchas & phase boundaries

- **Phone-sent messages have no special flag.** They are ordinary history rows; `is_self` (author
  == you) is the only signal that they were yours. Get `auth.test.user_id` right or the headline
  acceptance fails (§4.3).
- **`ts` is not a number.** Store the exact string; only *derive* `posted_at`. Rounding the `ts`
  breaks `UNIQUE(conversation_id, ts)` and the `oldest`/`replies` params (slack-api.md §6.3).
- **`oldest` is exclusive.** Set it to the last stored `ts`; the unique upsert makes any boundary
  overlap harmless anyway (slack-api.md §4.3).
- **Threads are a second call.** `conversations.history` returns roots/standalones only; fetch
  replies for roots seen this run (or whose `reply_count` changed) — don't re-pull settled threads
  (slack-api.md §4.4).
- **DMs have no `name`.** Resolve the peer via `users.info(im.user)` for `conversation_name`.
- **`mrkdwn` stays raw.** Store `<@U…>`/`<#C…|name>`/`<url|label>` tokens verbatim; resolve for
  display in the Phase-5 recap, not at ingest.
- **Phase boundary — classification.** Slack sessions ship **unclassified**; client attribution via
  entity signals is Phase 5. "Attributed to the right conversations" ≠ "attributed to the right
  client."
- **Phase boundary — pools.** Phase 4 seeds pools by producing sub-threshold slack sessions; the
  `pools` table and accumulator are Phase 5 (§6).
- **Rate-limit exemption may drift** (⚠️ Build-time check). If the internal-app exemption tightens,
  stretch cadences, drop `limit` to 15, or move to Events API/Socket Mode (slack-api.md §7,
  PLAN §12 "Slack policy drift").

---

## 12. Definition of done

- [ ] `make build` + `make test` green; new Slack fixtures committed (secrets stripped).
- [ ] Guided install produces a verified `xoxp-…` token in the Keychain; `doctor` shows Slack
      auth status.
- [ ] A real morning of Slack (incl. a phone-sent message) reads back on the `doctor` timeline as
      `kind='slack'` sessions grouped by conversation, `is_self` correct, threads intact.
- [ ] Re-sync is idempotent; cursors advance only on success; a `429` recovers cleanly.
- [ ] Guardrail tests green: Slack client is read-only (allowlist), no secret in logs/fixtures,
      retention purge does not re-import.
- [ ] The `v1-slack` migration creates `slack_messages` exactly per
      [data-model.md](../architecture/data-model.md), and the new `slack:*` `sync_state` rows behave
      as specified; no drift from the canonical DDL.
- [ ] Phase docs / acceptance criteria reflect any behavior that changed during the build.

**Next:** [Phase 5 — Recap & rules](phase-5-recap-rules.md) turns this captured Slack (plus
screens, meetings, calendar, and the Productive mirror) into the first end-to-end
"what did I miss today?" — rules + lexical attribution, pools, gap analysis, and the recap window.

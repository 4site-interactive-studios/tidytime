# Slack Web API (internal app)

Read-only ingest of the user's Slack messages (DMs, group DMs, private + public channels) via a
custom **internal** app in the 4Site workspace, polled on a cursor, mapped into `slack_messages`.
Covers PLAN §5 "Slack" and Phase 4.

**Related:** [docs index](../README.md) · [PLAN.md](../../PLAN.md) ·
[permissions-setup.md](../permissions-setup.md) (bundled manifest) ·
[data-model.md](../architecture/data-model.md) · [guardrails.md](../guardrails.md) ·
[phase-4-slack.md](../phases/phase-4-slack.md)

**Status:** reference (Phase 4) ·
**Base URL:** `https://slack.com/api/` ·
**Auth:** `Authorization: Bearer xoxp-…` (a **user** token; stored in Keychain only — G6) ·
**Source:** <https://docs.slack.dev/reference/methods> ·
<https://docs.slack.dev/apis/web-api/rate-limits> ·
<https://docs.slack.dev/changelog/2025/05/29/rate-limit-changes-for-non-marketplace-apps/> ·
<https://docs.slack.dev/changelog/2025/06/03/rate-limits-clarity/> ·
**Last verified:** 2026-07-23

---

## 1. Why Slack, why an internal app

Slack ingest catches billable micro-work that screen-watching never sees: drive-by help in DMs
and channels, and — critically — **Slack activity done from the user's phone**, which no on-device
capture can observe. Captured messages seed the timeline (a `sessions` row with `kind='slack'`,
`source_ref=<conversation_id>`) and feed micro-work pools ([suggestion-engine.md](../architecture/suggestion-engine.md)).

The app is a **custom internal app** in the 4Site workspace (the user has workspace admin, so
creation + install are self-serve; no Slack Marketplace review). Internal-app status is also what
keeps polling viable under Slack's 2025 rate-limit regime — see [§7](#7-rate-limits-the-2025-crackdown).

v1 is **poll-only**. Socket Mode / the Events API is a later optimization, not a v1 need
(PLAN §5). This client issues only reads; it never posts, reacts, or writes.

## 2. Scopes (user-token)

The app requests these **user-token** scopes (install produces one `xoxp-…` token acting as the
user). The manifest that declares them ships bundled — see
[permissions-setup.md](../permissions-setup.md); confirm the exact list in the manifest editor,
which validates names.

| Scope | Grants |
|---|---|
| `channels:read` | list public channels the user is in; channel metadata |
| `channels:history` | read message history of public channels |
| `groups:read` | list private channels the user is in |
| `groups:history` | read message history of private channels |
| `im:read` | list the user's DMs |
| `im:history` | read DM message history |
| `mpim:read` | list the user's group DMs (multi-person IMs) |
| `mpim:history` | read group-DM message history |
| `users:read` | resolve user ids → display names |
| `users:read.email` | resolve user ids → email (a client signal via domain) |

> ⚠️ Build-time check: verify this scope list against the manifest editor when the app is created
> (PLAN §14 open item 3). Missing a `*:history` scope surfaces at runtime as
> `{"ok":false,"error":"missing_scope","needed":"…"}`.

Slack's modern model puts **private channels in the `channels` array** of `conversations.list`
(with `is_private:true`), yet history/read still gate on the legacy `groups:*` scopes — so both
`channels:*` and `groups:*` are required.

## 3. Request/response conventions

- **Transport:** HTTP GET (or POST) to `https://slack.com/api/<method>`. Reads use GET with query
  params; `Authorization: Bearer <token>` header. Slack accepts params as query string or
  `application/x-www-form-urlencoded` body.
- **Every response is `200 OK`** at the HTTP layer (except `429`); success is the JSON body's
  `"ok": true`. On failure, `{"ok":false,"error":"<code>"}` — always branch on `ok`, never on the
  HTTP status alone.
- **Common error codes:** `ratelimited` (paired with HTTP 429 + `Retry-After`), `missing_scope`
  (with `needed`/`provided`), `invalid_auth`, `token_revoked`, `not_in_channel`,
  `channel_not_found`.

```http
GET /api/conversations.history?channel=C0123ABYZ&oldest=1721739000.000000&limit=200 HTTP/1.1
Host: slack.com
Authorization: Bearer xoxp-…
```

## 4. Endpoints used

| Method | Purpose | Key params | Default rate tier |
|---|---|---|---|
| `auth.test` | resolve the authed user's own `user_id` (for `is_self`) + workspace URL | — | Tier 3 |
| `conversations.list` | enumerate conversations to sync | `types`, `exclude_archived`, `limit`, `cursor` | Tier 2 (~20/min) |
| `conversations.history` | pull messages for one conversation | `channel`, `oldest`, `latest`, `inclusive`, `limit`, `cursor` | Tier 3 (~50/min)* |
| `conversations.replies` | pull a thread's replies | `channel`, `ts`, `oldest`, `limit`, `cursor` | Tier 3 (~50/min)* |
| `users.list` | bootstrap the id→name/email map | `limit`, `cursor` | Tier 2 |
| `users.info` | resolve a single user (cache-miss fill) | `user` | Tier 4 (~100/min) |
| `chat.getPermalink` | permalink for a captured message | `channel`, `message_ts` | Tier 4 |

\* For an **internal** app these two methods keep the ~50+/min, 1,000-object behavior; the 2025
crackdown (1/min, 15 objects) does not apply. See [§7](#7-rate-limits-the-2025-crackdown).

### 4.1 `auth.test` — who am I (once at setup, re-checked on token change)

```json
{
  "ok": true,
  "url": "https://4site.slack.com/",
  "team": "4Site",
  "user": "bryan",
  "team_id": "T024ABC",
  "user_id": "U024SELF01"
}
```

Store `user_id` in memory for the sync run; a `slack_messages.is_self` is set when a message's
`user == user_id`. `url` gives the workspace host for permalink fallback construction ([§6.4](#64-permalinks)).

### 4.2 `conversations.list` — what to sync

Request all four conversation kinds in one call and page the cursor:

```http
GET /api/conversations.list?types=public_channel,private_channel,mpim,im&exclude_archived=true&limit=200
```

```json
{
  "ok": true,
  "channels": [
    { "id": "C0123ABYZ", "name": "client-acme", "is_channel": true,  "is_private": false, "is_member": true },
    { "id": "C07PRIV22", "name": "proj-4site",  "is_channel": true,  "is_private": true,  "is_member": true },
    { "id": "G05MPIM33", "is_mpim": true,  "is_group": true, "name": "mpdm-bryan--nick--sebrinia-1" },
    { "id": "D08IM4444", "is_im": true,   "user": "U04NICK00" }
  ],
  "response_metadata": { "next_cursor": "dGVhbTpDMDYxRkE1UEI=" }
}
```

Map each object to `slack_messages.conversation_type` from its booleans, in this order:

| Condition | `conversation_type` | Name source |
|---|---|---|
| `is_im == true` | `im` | `users.info(user).real_name` (DMs have no `name`) |
| `is_mpim == true` | `mpim` | `name` (the `mpdm-…` slug) |
| `is_private == true` (and not im/mpim) | `group` | `name` |
| else (public) | `channel` | `name` |

Notes:
- With a user token, `conversations.list` returns public channels regardless of membership, but
  `im`/`mpim`/private entries only where the user is a member. History reads require membership;
  filter to `is_member == true` for public channels (skip `not_in_channel` noise), and treat all
  `im`/`mpim`/private results as readable.
- Refresh this list every few minutes; it's cheap. New DMs/channels appear here first.

### 4.3 `conversations.history` — incremental pull

Cursor by Slack `ts` using `oldest` (strictly-after semantics), then page `next_cursor`:

```http
GET /api/conversations.history?channel=C0123ABYZ&oldest=1721739000.000000&limit=200
```

```json
{
  "ok": true,
  "messages": [
    { "type": "message", "user": "U04NICK00", "text": "can you review the staging link?",
      "ts": "1721739600.001500", "thread_ts": "1721739600.001500", "reply_count": 3, "reply_users_count": 2 },
    { "type": "message", "user": "U024SELF01", "text": "on it — looking now", "ts": "1721739550.000900" },
    { "type": "message", "subtype": "channel_join", "user": "U04NICK00", "text": "has joined the channel",
      "ts": "1721700000.000100" }
  ],
  "has_more": true,
  "response_metadata": { "next_cursor": "bmV4dF90czoxNzIxNzM5NTUwMDAwOTAw" }
}
```

Ingest rules:
- **Skip non-conversational rows.** Ignore messages carrying a `subtype` that isn't real user
  content (`channel_join`, `channel_leave`, `bot_message` without a `user`, etc.). Keep plain
  `type:"message"` rows (no `subtype`, or benign edits). A row with no `user` (only `bot_id`) has
  `is_self=0` and `user_id=NULL`.
- **`oldest` is exclusive** ("only messages after this Unix timestamp"). Set
  `oldest = <max ts stored for this conversation>`; the `UNIQUE(conversation_id, ts)` upsert makes
  any boundary overlap harmless anyway.
- `conversations.history` returns **thread parents and standalone messages only** — thread replies
  are not inlined. Any message with `reply_count > 0` (or a `thread_ts == ts`, i.e. it's a root)
  needs a `conversations.replies` follow-up ([§4.4](#44-conversationsreplies--threads)).

### 4.4 `conversations.replies` — threads

For each thread root, fetch replies with the root `ts`:

```http
GET /api/conversations.replies?channel=C0123ABYZ&ts=1721739600.001500&limit=200
```

```json
{
  "ok": true,
  "messages": [
    { "type": "message", "user": "U04NICK00", "text": "can you review the staging link?",
      "ts": "1721739600.001500", "thread_ts": "1721739600.001500", "reply_count": 3 },
    { "type": "message", "user": "U024SELF01", "text": "selector was scoped wrong; fixed",
      "ts": "1721739720.002000", "thread_ts": "1721739600.001500" },
    { "type": "message", "user": "U04NICK00", "text": "confirmed, thanks",
      "ts": "1721740050.002300", "thread_ts": "1721739600.001500" }
  ],
  "has_more": false
}
```

The first element is the **root repeated** — the `UNIQUE(conversation_id, ts)` upsert dedupes it.
Every reply carries `thread_ts` (the root's `ts`); store it in `slack_messages.thread_ts` so the
recap can regroup a thread. Only fetch replies for roots seen in this run (or whose `reply_count`
changed) to avoid re-pulling settled threads.

### 4.5 `users.list` / `users.info` — names & emails

Bootstrap once per sync with `users.list` (paged) into an in-memory `[user_id: (name, email)]`
cache; fall back to `users.info` on a miss. There is no Slack users table in the schema — names
are denormalized onto `slack_messages.user_name` at ingest time.

```json
{
  "ok": true,
  "user": {
    "id": "U04NICK00",
    "name": "nick",
    "real_name": "Nick Rivera",
    "profile": { "real_name": "Nick Rivera", "display_name": "Nick", "email": "nick@acme.org" }
  }
}
```

`profile.email` (needs `users.read.email`) yields an `email_domain` — feed it to
`entity_signals` as `signal_type='person_email'` / `'email_domain'` for client attribution
([understand-layer.md](../architecture/understand-layer.md)). Prefer `profile.display_name`, else
`real_name`, else `name` for `user_name`.

## 5. Sync loop & cursors

Persist per-conversation progress in `sync_state`, one row per conversation, keyed
`slack:<conversation_id>` (matches [data-model.md](../architecture/data-model.md)); `cursor` holds
the latest `ts` seen for that conversation.

```
every ~3–5 min (Phase 4 poller; back off when idle):
  auth.test once per process (cache user_id)
  conversations.list(types=…) → upsert the working set of conversations
  for each conversation the user can read:
    oldest = sync_state["slack:<id>"].cursor            # last max ts, or 0 on first run
    page conversations.history(channel, oldest, limit=200) via next_cursor
      → upsert each kept message; track max(ts)
      → for each thread root, page conversations.replies(channel, ts) → upsert
    sync_state["slack:<id>"].cursor = max(ts seen)       # advance only on success
    write last_run_at / last_success_at / last_error
```

- **`limit`:** request 200 (well under the internal-app 1,000 cap; Slack recommends ≤200 pages).
- **Prioritize** conversations with recent activity; a conversation whose first history page is
  empty costs one request and moves on.
- Sync is **idempotent** via the unique index — a crash mid-page re-runs safely.

## 6. Field mapping → `slack_messages`

Target table (verbatim from [data-model.md](../architecture/data-model.md)):

```sql
CREATE TABLE slack_messages (
    id                INTEGER PRIMARY KEY,
    conversation_id   TEXT NOT NULL,             -- channel/DM id
    conversation_type TEXT NOT NULL,             -- 'channel' | 'group' | 'im' | 'mpim'
    conversation_name TEXT,
    ts                TEXT NOT NULL,             -- Slack message ts (unique within conversation)
    posted_at         INTEGER NOT NULL,          -- epoch derived from ts
    user_id           TEXT,
    user_name         TEXT,
    is_self           INTEGER NOT NULL DEFAULT 0,-- authored by the user (incl. from phone)
    thread_ts         TEXT,
    text              TEXT,
    permalink         TEXT,
    fetched_at        INTEGER NOT NULL,
    UNIQUE(conversation_id, ts)
);
```

| Slack field | Column | Transform |
|---|---|---|
| conversation `id` | `conversation_id` | as-is |
| conversation booleans | `conversation_type` | map per [§4.2](#42-conversationslist--what-to-sync) |
| conversation `name` / DM peer name | `conversation_name` | as-is / peer `real_name` for `im` |
| message `ts` | `ts` | keep the **exact string** (uniqueness key) |
| message `ts` | `posted_at` | `floor(Double(ts))` → epoch seconds ([§6.3](#63-tsepoch-conversion)) |
| message `user` | `user_id` | as-is; `NULL` if bot-only |
| resolved name | `user_name` | from users cache |
| `user == auth.test.user_id` | `is_self` | `1`/`0` |
| message `thread_ts` | `thread_ts` | present only for threaded messages |
| message `text` | `text` | raw Slack markup (mrkdwn); resolve `<@U…>`/`<#C…>` lazily in UI |
| `chat.getPermalink` | `permalink` | [§6.4](#64-permalinks) |
| now | `fetched_at` | epoch seconds |

### 6.1 Upsert (idempotent, matches the unique index)

```sql
INSERT INTO slack_messages
  (conversation_id, conversation_type, conversation_name, ts, posted_at,
   user_id, user_name, is_self, thread_ts, text, permalink, fetched_at)
VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
ON CONFLICT(conversation_id, ts) DO UPDATE SET
  conversation_name = excluded.conversation_name,
  user_name         = excluded.user_name,
  text              = excluded.text,          -- picks up edits
  thread_ts         = excluded.thread_ts,
  permalink         = COALESCE(slack_messages.permalink, excluded.permalink),
  fetched_at        = excluded.fetched_at;
```

### 6.2 GRDB record sketch (`TidyStore`)

```swift
struct SlackMessage: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var conversationId: String       // conversation_id
    var conversationType: String     // 'channel' | 'group' | 'im' | 'mpim'
    var conversationName: String?
    var ts: String                   // exact Slack ts string
    var postedAt: Int                // epoch seconds
    var userId: String?
    var userName: String?
    var isSelf: Bool
    var threadTs: String?
    var text: String?
    var permalink: String?
    var fetchedAt: Int
}
```

### 6.3 `ts` ↔ epoch conversion

A Slack `ts` is a string like `"1721739600.001500"`: the integer part is Unix epoch **seconds**;
the fractional part is a per-conversation uniqueness/sequence counter (**not** microseconds you can
add meaningfully). Rules:
- **Keep `ts` as the original string** for `UNIQUE(conversation_id, ts)`, `oldest`/`latest`
  params, and `conversations.replies` lookups. Never round-trip it through a `Double` for storage
  (precision loss breaks the key).
- **Derive `posted_at`** as the floored seconds only for indexing/ordering:

```swift
// epoch seconds for posted_at; ts string is preserved separately
let postedAt = Int(ts.split(separator: ".").first.map(String.init) ?? "0") ?? 0
// epoch → Slack ts arg (fractional zero-pad) when building `oldest`
func slackTs(fromEpoch s: Int) -> String { String(format: "%d.000000", s) }
```

### 6.4 Permalinks

`conversations.history`/`replies` do **not** include a permalink. Two options:
1. **`chat.getPermalink`** (authoritative, one call per message — Tier 4):

   ```json
   { "ok": true, "channel": "C0123ABYZ",
     "permalink": "https://4site.slack.com/archives/C0123ABYZ/p1721739600001500" }
   ```
2. **Construct it (zero calls)** from `auth.test.url` + channel + `ts` (drop the dot, prefix `p`);
   for a threaded reply append `?thread_ts=<root>&cid=<channel>`:

   ```
   https://4site.slack.com/archives/C0123ABYZ/p1721739600001500
   ```

Prefer construction for volume; reserve `chat.getPermalink` for messages the recap actually
surfaces (keeps request count low). Store whatever you resolve in `permalink`.

## 7. Rate limits: the 2025 crackdown

The rate-limit question is the reason internal-app status matters, and the answer is favorable.

- **May 29, 2025 change (`docs.slack.dev` changelog).** For **commercially distributed
  non-Marketplace apps** — created after that date, and net-new installs of existing such apps —
  `conversations.history` **and** `conversations.replies` are throttled to **1 request/minute** and
  the `limit` param max/default is cut to **15 objects**, unless the app is Slack-Marketplace
  approved. Existing installs phase in Sept 2, 2025 → Mar 3, 2026.
- **Internal customer-built apps are explicitly exempt.** They are "not impacted"; for these apps
  `conversations.history`/`replies` keep the prior behavior — roughly **50+ requests/minute** and
  **up to 1,000 objects** per call (the June 3, 2025 clarification restates this).
- **Consequence for TidyTime:** because the app is internal to the 4Site workspace, **plain
  polling works** at the cadence in [§5](#5-sync-loop--cursors). No Marketplace listing, no Events
  API, no Socket Mode required for v1.

> ⚠️ Build-time check: confirm the internal-app exemption is still in force when the app is
> created (re-read the changelog + rate-limits page). If it ever tightens, the mitigations are:
> stretch the poll interval, drop `limit` to 15, and move to the Events API / Socket Mode
> (PLAN §12 "Slack policy drift"). The [ingest-layer](../architecture/ingest-layer.md) retry path
> already handles the tightened case generically.

### 7.1 Handling `429`

Regardless of exemption, honor throttling defensively — it's the one HTTP status Slack returns
outside `200`:

```http
HTTP/1.1 429 Too Many Requests
Retry-After: 30
```

```json
{ "ok": false, "error": "ratelimited" }
```

Sleep `Retry-After` seconds (default to a sane fallback if absent), then retry the *same* cursor
page. Never advance `sync_state.cursor` on a non-success. Record `last_error` for the `doctor` view.

## 8. Guardrails that bind this client

- **G1 (read-only Productive):** N/A to Slack directly, but this client is likewise **read-only** —
  no `chat.postMessage`, reactions, or any write. The requested scopes are all `:read`/`:history`.
- **G2 (sensitivity gate fails closed):** Slack `text` is high-risk (personnel/comp/legal chatter
  in DMs). It is stored locally, but **before any Slack content enters a cloud payload** (rungs 4–5)
  it passes the sensitivity gate; tripped content never leaves the device and its session defaults
  to a generic task with a bland note. See [guardrails.md](../guardrails.md) G2 and
  [understand-layer.md](../architecture/understand-layer.md).
- **G6 (secrets in Keychain):** the `xoxp-…` token lives in the Keychain via `SecretStore`; it is
  never in `config.json`, logs, or the outbound-payload log. Redact `Authorization` on any logged
  request.
- **G9 (retention):** `slack_messages` is a raw/sensitive table — it **purges after the retention
  window** (default 90 days). Distilled `sessions`/`suggestions` derived from it persist. The
  retention job covers this table (see [data-model.md](../architecture/data-model.md) Retention).

## 9. Testing (fixtures, no live network)

Per [module-map.md](../architecture/module-map.md), the Slack client sits behind an `IngestSource`
protocol and is unit-tested with **recorded fixtures** — capture one real JSON response per method
(`auth.test`, `conversations.list`, `conversations.history` with a threaded root, one
`conversations.replies`, `users.info`) into `Tests/.../Fixtures/slack/`, strip the token, and
assert:
- conversation-type mapping across all four kinds (public, private, im, mpim);
- `ts` preserved verbatim and `posted_at` correctly floored;
- `is_self` set when `user == auth.test.user_id`;
- thread replies upsert without duplicating the repeated root (unique index);
- a subtype row (`channel_join`) is skipped;
- a seeded sensitive phrase in a fixture message appears in **no** outbound cloud payload (shared
  G2 assertion, Phase 6).

## 10. Open items / gotchas

- **Scope validation** at manifest time (PLAN §14.3) — the bundled manifest is the source; the
  editor validates names. Link: [permissions-setup.md](../permissions-setup.md).
- **mrkdwn in `text`:** stored raw with `<@U…>`, `<#C…|name>`, `<https://…|label>` tokens; resolve
  for display in the recap UI, not at ingest.
- **`im` names:** DMs have no `name`; resolve the peer via `users.info(im.user)` for
  `conversation_name`.
- **Bot/app messages:** kept only if they carry a `user`; otherwise `user_id=NULL`, `is_self=0`.
  They rarely signal billable work — lexical/rules can down-weight them downstream.
- **Deleted/edited messages:** edits arrive as the same `ts` with new `text`; the upsert refreshes
  `text`. Tombstoned deletes are surfaced as `subtype:"message_deleted"` in some contexts — treat
  as skip; the 90-day purge handles the rest.

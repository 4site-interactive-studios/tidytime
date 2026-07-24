# Ingest layer (TidyIngest)

The read-only API layer: incremental sync engines for Productive, Fathom, Google Calendar, and
Slack that poll each provider on its own cadence and UPSERT results into the local cache. Every
client is a protocol tested with recorded fixtures; **no source ever issues a write** (PLAN §5).

Related: [../README.md](../README.md) · [../../PLAN.md](../../PLAN.md) ·
[data-model.md](data-model.md) · [module-map.md](module-map.md) ·
[capture-layer.md](capture-layer.md) · [understand-layer.md](understand-layer.md) ·
[../guardrails.md](../guardrails.md)

Reference (exact endpoints/headers/JSON live here, not below):
[../reference/productive-api.md](../reference/productive-api.md) ·
[../reference/fathom-api.md](../reference/fathom-api.md) ·
[../reference/google-calendar-api.md](../reference/google-calendar-api.md) ·
[../reference/slack-api.md](../reference/slack-api.md)

---

## 1. What this layer does

`TidyIngest` mirrors the slices of four external services that attribution needs into local
cache tables, then keeps them fresh with **incremental** polling. It writes only through
`TidyStore` DAOs; it reads secrets only through `TidyCore`'s `SecretStore` (Keychain). It has
**no** dependency on `TidyCapture` or `TidyAI` (see [module-map.md](module-map.md) — the three
meet only through the store).

| Provider | Fills tables | Reference |
|---|---|---|
| Productive | `pd_companies`, `pd_projects`, `pd_tasks`, `pd_time_entries`, `pd_people` | [productive-api.md](../reference/productive-api.md) |
| Fathom | `meetings`, `meeting_invitees`, `transcript_utterances` | [fathom-api.md](../reference/fathom-api.md) |
| Google Calendar | `calendar_events`, back-links `meetings.calendar_event_id` | [google-calendar-api.md](../reference/google-calendar-api.md) |
| Slack | `slack_messages` | [slack-api.md](../reference/slack-api.md) |

Cursors for all of them live in one table, **`sync_state`** (one row per source), created in
Phase 1 so the plumbing exists before the first source lands. See
[data-model.md → Capture tables](data-model.md#capture-tables-phase-1).

**Phase placement:** Productive = Phase 2, Fathom + Calendar = Phase 3, Slack = Phase 4. The
`IngestSource` protocol, `IngestCoordinator`, shared `HTTPClient`, and backoff land with the
first source (Phase 2) and every later source plugs into them.

---

## 2. The read-only invariant (G1) is architectural, not incidental

Read-only for Productive is a **release-blocking guardrail** ([../guardrails.md](../guardrails.md) G1),
so the ingest layer is built so a write is not merely discouraged but hard to express:

- The shared request builder for the Productive host accepts only `HTTPMethod.get`. There is
  no code path in `LiveProductiveClient` that constructs a `POST`/`PUT`/`PATCH`/`DELETE`
  `URLRequest` against `api.productive.io`. A guardrail unit test asserts the builder
  rejects/aborts any non-`GET` method (fail loudly in `DEBUG`).
- `ProductiveClient` (the protocol seam in [module-map.md](module-map.md#protocol-seams-the-extension-points))
  exposes **no** mutating methods. A v2 write client would be a *separate* type, never a method
  added here.
- Fathom and Google Calendar clients are likewise `GET`-only.
- Slack's Web API is `POST`-based even for reads, so "GET-only" cannot be the test there.
  Instead the Slack invariant is enforced two ways: (a) the app is installed with **read-only
  scopes only** (`*:history`, `*:read`, `users:read[.email]` — no `chat:write`, no write scope
  exists to call), and (b) `LiveSlackClient` calls only a compile-time **allowlist** of read
  methods (`conversations.list`, `conversations.history`, `conversations.replies`,
  `conversations.info`, `users.info`, `users.list`). A test asserts no other method string is
  ever passed to the transport.

This layer is a mirror. Nothing it does mutates a provider's state.

> Ingest polling is **not** metered AI. It writes nothing to `ai_calls` and is not bound by the
> cloud budget caps (G5) — those govern rungs 3–5 in [../architecture/classification-ladder.md](classification-ladder.md).
> Ingest has its own rate-limit discipline (§6).

---

## 3. The `IngestSource` protocol

Every source is one conforming type. It owns its client, its `sync_state` row(s), its cadence,
and its UPSERT logic. The coordinator (§5) knows nothing provider-specific — it only reads
`sourceKey` / `cadence` and calls `sync(_:)`.

```swift
import Foundation

/// A read-only ingest source: one per provider (Productive, Fathom, Google
/// Calendar) or one per Slack conversation shard. Owns its `sync_state` row(s),
/// fetches only what is new since its cursor, UPSERTs into the cache, and
/// advances the cursor — all in a single write transaction so a crash can never
/// leave the cursor ahead of the data. Never issues a mutating request.
public protocol IngestSource: Sendable {

    /// Stable identity; also the `sync_state.source` primary-key value.
    /// e.g. "productive", "fathom", "google_calendar",
    /// "slack:conversations", or "slack:<conversation_id>".
    var sourceKey: String { get }

    /// How often the coordinator should attempt a sync for this source.
    var cadence: Duration { get }

    /// Perform one incremental sync. Implementations:
    ///   1. read the cursor from `sync_state` for `sourceKey`,
    ///   2. fetch only rows newer than the cursor (paging as needed),
    ///   3. UPSERT into the cache tables,
    ///   4. advance the cursor and stamp `last_success_at`,
    /// wrapping (2b)–(4) writes in one DB transaction. Idempotent: a repeat run
    /// with an unchanged cursor is a no-op beyond touching `last_run_at`.
    /// Throws `IngestError` for transport/decoding faults; the coordinator
    /// records `last_error` and does NOT advance the cursor on throw.
    @discardableResult
    func sync(_ ctx: SyncContext) async throws -> SyncOutcome
}

/// Injected dependencies — keeps sources free of global singletons and makes
/// them unit-testable with an in-memory store and a fixture client.
public struct SyncContext: Sendable {
    public let store: IngestStore   // TidyStore write facade (DAOs + sync_state)
    public let secrets: SecretStore // Keychain-backed; tokens never touch config/logs (G6)
    public let clock: any Clock     // injectable time (deterministic in tests)
}

public struct SyncOutcome: Sendable {
    public var fetched: Int         // rows/objects pulled from the provider
    public var upserted: Int        // rows written/updated locally
    public var newCursor: String?   // cursor value persisted this run (nil = unchanged)
    public var rateLimited: Bool    // a 429/backoff occurred (surfaced to metrics/doctor)
}
```

`Clock`, `SecretStore`, and `IngestSource` are the seams from
[module-map.md](module-map.md#protocol-seams-the-extension-points). The Fathom-webhook upgrade
(PLAN §5, §13) is a *new* `IngestSource` that replaces `FathomSource` polling — the coordinator
is untouched.

### `sync_state` cursor helpers

The cursor contract lives on `IngestStore` so every source manages its row identically:

```swift
public protocol IngestStore: Sendable {
    /// Reads `sync_state.cursor` for `source` (nil if the row/cursor is unset).
    func cursor(for source: String) async throws -> String?

    /// Runs `body` in one write transaction, then advances the cursor and stamps
    /// last_run_at / last_success_at. If `body` throws, the transaction rolls
    /// back, cursor is unchanged, and last_error is recorded (last_run_at only).
    func syncTransaction<T>(
        source: String,
        newCursor: @autoclosure () -> String?,
        _ body: (Database) throws -> T
    ) async throws -> T
}
```

Design rules for cursors:

- **Forward-only.** A cursor never rewinds, so retention purges (G9) can drop old
  `slack_messages` / `transcript_utterances` without them being re-imported on the next poll.
- **Advanced only on success**, and only inside the same transaction as the UPSERTs, so DB and
  cursor can't diverge.
- **Opaque where the provider says so.** Google's `syncToken` is stored verbatim; never parsed.

---

## 4. Source → cursor semantics

The four providers offer four different incremental mechanisms. Each source adapts its provider
to the single `sync_state.cursor` string.

| Source (`sync_state.source`) | Cursor stored in `cursor` | Fetch mechanism | Advance rule |
|---|---|---|---|
| `productive` | date-window high-water: last fully-synced day `YYYY-MM-DD` (governs `pd_time_entries`) | `filter[after]=…&filter[before]=…` on time entries; bounded full page-walk of companies/projects/tasks/people (small — a handful of requests) | advance to *today*, but always re-sync a trailing **window** (default 14 days) to catch edited/back-dated entries |
| `fathom` | `created_after` = max meeting `created_at` seen (RFC 3339) | `GET /meetings?created_after=<cursor>&include_transcript=true&include_summary=true` | advance to the newest meeting's `created_at` on success |
| `google_calendar` | opaque `syncToken` from `events.list` | incremental `events.list(syncToken=<cursor>)`; **first run** uses `timeMin`/`timeMax` window + `singleEvents=true` and stores the returned `nextSyncToken` | store `nextSyncToken` from the last page; on **410 GONE** drop the token and full-resync the window |
| `slack:conversations` | last list-refresh marker (epoch secs; optional) | `conversations.list` (+ each conv's `latest.ts`) to discover which conversations have new activity | not a message cursor — it schedules per-conversation history pulls (§5.1) |
| `slack:<conversation_id>` | latest message `ts` ingested for that conversation | `conversations.history(oldest=<cursor>)` + `conversations.replies` for threads with new replies | advance to the newest `ts` written on success |

Notes:

- **Productive is windowed, not tokened.** There is no server-side change feed in v1's usage;
  the trailing-window re-sync is what catches a colleague editing yesterday's note. The static
  reference tables (companies/projects/tasks/people) are cheap enough to refresh in full each
  cycle, so their "cursor" is effectively `synced_at` freshness, not a filter.
- **Fathom `created_after`** keys off recording *creation*, so a meeting that finishes and
  processes late still appears once its content is ready. ⚠️ Build-time check: confirm whether
  `created_after` filters on recording-creation vs. scheduled time against
  [fathom-api.md](../reference/fathom-api.md); adjust the advance rule if it is scheduled time.
- **Calendar `syncToken`** returns changed *and cancelled* events since the token; cancellations
  arrive as `status: "cancelled"` and are UPSERTed (row kept, `status` updated) so downstream can
  ignore them. A 410 means the token expired — this is expected, not an error; fall back to a
  timed window and mint a fresh token.
- **Slack per-conversation `ts`** is the string message id (`"1690000000.000200"`); it is unique
  and monotonically increasing within a conversation, which is exactly a cursor.

---

## 5. Scheduling & the coordinator

One in-process `IngestCoordinator` (an `actor`) drives all sources. **No daemons, no launchd,
no XPC** — G8: everything runs as `async` Tasks inside the single menu-bar app process. If the
app isn't running, ingest is off, same as capture.

Per-source cadences (PLAN §5; each is a `config.json` default, tunable):

| Source | Cadence | Why |
|---|---|---|
| `productive` | **~15 min** | A full refresh of your org slice is a handful of requests, nowhere near limits; billing data doesn't change minute-to-minute. |
| `fathom` | **~10 min** | Recordings appear minutes after a call ends; 10 min keeps the recap current without hammering the 30/min transcript limit. |
| `google_calendar` | **~10 min** | Catches newly-accepted invites and reschedules; `syncToken` makes each poll tiny. |
| `slack:conversations` | **~5 min** | Cheap list scan to find which conversations moved. |
| `slack:<conv>` (history) | **~3 min** (only for active convs) | Drive-by DMs are time-sensitive for pools; history is pulled only where the list scan saw new `ts`. |

Coordinator behavior:

```swift
public actor IngestCoordinator {
    private var sources: [IngestSource]
    private var nextFire: [String: ContinuousClock.Instant] = [:]
    private var inFlight: Set<String> = []          // per-source serialization
    private let ctx: SyncContext

    /// Registered sources run on their own cadence. Initial syncs are staggered
    /// (jittered) on launch so four providers don't fire at once.
    public func run() async {
        for src in sources { scheduleInitial(src) }   // now + random(0…cadence/2)
        while !Task.isCancelled {
            let due = dueSources(at: ctx.clock.now)
            await withTaskGroup(of: Void.self) { group in
                for src in due where !inFlight.contains(src.sourceKey) {
                    inFlight.insert(src.sourceKey)
                    group.addTask { await self.runOne(src) }
                }
            }
            try? await Task.sleep(for: .seconds(15))   // tick; real waits are per-source
        }
    }

    private func runOne(_ src: IngestSource) async {
        defer { inFlight.remove(src.sourceKey)
                nextFire[src.sourceKey] = ctx.clock.now.advanced(by: jittered(src.cadence)) }
        do    { _ = try await src.sync(ctx) }
        catch { /* last_error already persisted by syncTransaction; log via TidyLog */ }
    }
}
```

- **Per-source serialization.** A source already running is skipped this tick, never run
  concurrently with itself (avoids double-paging and cursor races).
- **Jitter** (±25% of cadence) prevents a synchronized thundering herd across providers.
- **Kill switches.** Settings exposes a per-source enable flag (PLAN §9 "kill switches per
  source"); a disabled source is not registered / is removed from the schedule.
- **Pause capture** pauses ingest too — the menu-bar "paused" state stops the coordinator loop.
- **Backoff overrides cadence.** A `429` (§6) reschedules that source to `now + backoff` instead
  of `now + cadence`.

### 5.1 Slack's two-tier scheduling

Slack is the one provider that shards into many `sync_state` rows:

1. `SlackConversationsSource` (`slack:conversations`, ~5 min) calls `conversations.list` and reads
   each conversation's `latest.ts`. For any conversation whose `latest.ts` is newer than that
   conversation's stored cursor (`slack:<id>`), it marks the conversation **active** for this
   cycle.
2. `SlackHistorySource` instances (one logical fetcher, ~3 min) pull `conversations.history` for
   **active** conversations only, `oldest=<cursor>`, then `conversations.replies` for threads with
   new activity. Inactive conversations cost zero history calls.

This keeps Slack within the internal-app budget (§6) while still catching phone-sent messages
(they arrive in history like any other). See PLAN §5 (Slack) and
[slack-api.md](../reference/slack-api.md).

---

## 6. Rate limits & exponential backoff

Each provider gets its own limiter and its own backoff parameters. All backoff is **full-jitter
exponential**, capped, and **honors a server-supplied `Retry-After` first**.

| Provider | Documented limit | Signal on excess | Backoff strategy |
|---|---|---|---|
| **Productive** | 100 req / 10 s **and** 4,000 / 30 min | HTTP `429` | Client-side token bucket sized under the 10 s window; on `429`, obey `Retry-After` if present else exp backoff (base 1 s, cap 60 s, full jitter). A full refresh is a handful of requests, so this rarely trips. |
| **Fathom** | 60 calls/min; **30/min for heavy calls** (transcripts) | HTTP `429` | *Two* buckets: a general 60/min and a stricter 30/min for transcript-bearing calls. Fetch a meeting's transcript **once** (guard on `meetings.has_transcript`), so heavy calls scale with new meetings, not polls. |
| **Google Calendar** | Per-project quota (`userRateLimitExceeded` / `rateLimitExceeded`) | HTTP `403` (quota) or `429` | Exp backoff per Google guidance (base 1 s, cap 32–64 s, full jitter). `410 GONE` is **not** rate-limit — it means `syncToken` expired → full-resync (§4). |
| **Slack** | Internal customer app: ~50+ req/min, up to 1,000 objects/call (exempt from the May-2025 non-Marketplace crackdown) | HTTP `429` + `Retry-After` (seconds) | **Always obey `Retry-After` exactly** — Slack mandates it. Never retry faster. Use ≤1,000-object pages to minimize call count. |

⚠️ Build-time check: Slack's internal-app exemption and Fathom's exact heavy-call set are
per-vendor policy that can drift — confirm against [slack-api.md](../reference/slack-api.md) and
[fathom-api.md](../reference/fathom-api.md) at build time. If Slack ever tightens, stretch the
cadences (§5) and the Events API path (PLAN §5, §13) becomes the upgrade.

Shared backoff helper (in `TidyIngest/HTTP/`):

```swift
/// Full-jitter exponential backoff, capped. A server Retry-After always wins.
func backoffDelay(attempt: Int,
                  retryAfter: Duration?,
                  base: Duration = .seconds(1),
                  cap: Duration = .seconds(60)) -> Duration {
    if let ra = retryAfter { return ra }                 // Slack/Productive: obey exactly
    let stepped = min(cap, base * (1 << min(attempt, 6))) // 1,2,4,…,64s (capped)
    let ms = Int(stepped.components.seconds * 1000)
    return .milliseconds(Int.random(in: 0...max(1, ms))) // full jitter
}
```

Retry policy: transient (`429`, `5xx`, `URLError` timeouts/offline) → up to N attempts (default
5) with the delay above, then give up for this cycle — `last_error` is recorded, the cursor is
**not** advanced, and the next scheduled tick tries again. Auth failures (`401`/`403` non-quota)
are **not** retried on a loop; they surface to the `doctor` view as "re-auth needed" (e.g. an
expired Google refresh token, a rotated Slack token). Decoding faults fail the run and are logged
with the offending payload shape (never secrets, G6).

---

## 7. UPSERT-into-cache patterns

Every table's write is idempotent so re-syncs converge. Two shapes cover all six table families.

### 7.1 String-PK upsert (provider id is the primary key)

`pd_*`, `meetings`, and `calendar_events` use the provider's string id as PK
([data-model.md → Conventions](data-model.md#conventions)), so a re-sync is a plain UPSERT on
`id`. With GRDB, a `Codable` record's `save()`/`upsert()` does this; the equivalent SQL:

```sql
-- pd_tasks (Productive → Phase 2). Refetched wholesale each cycle for your projects.
INSERT INTO pd_tasks
    (id, project_id, task_list_id, title, description, task_number,
     status, closed, assignee_id, due_date, synced_at)
VALUES
    (:id, :project_id, :task_list_id, :title, :description, :task_number,
     :status, :closed, :assignee_id, :due_date, :synced_at)
ON CONFLICT(id) DO UPDATE SET
    project_id  = excluded.project_id,
    task_list_id= excluded.task_list_id,
    title       = excluded.title,
    description = excluded.description,
    task_number = excluded.task_number,
    status      = excluded.status,
    closed      = excluded.closed,
    assignee_id = excluded.assignee_id,
    due_date    = excluded.due_date,
    synced_at   = excluded.synced_at;
```

- **Archival, not deletion.** `pd_companies` / `pd_projects` carry `archived` (0/1); a project
  that leaves your active slice is marked `archived = 1`, never hard-deleted, so historical
  `sessions`/`suggestions` FKs stay valid.
- `meetings.duration_seconds` is computed on write: `recording_end − recording_start` when the
  recording span is present, else `scheduled_end − scheduled_start` (ground-truth rule, PLAN §5).
  Set `has_transcript`/`has_summary` from the payload; back-link `calendar_event_id` when a Fathom
  meeting matches a `calendar_events` row (by `ical_uid` / time+attendees).
- `calendar_events` cancellations: UPSERT with `status = 'cancelled'` (keep the row).

### 7.2 Replace-children (child rows keyed only by a local rowid)

`meeting_invitees` and `transcript_utterances` have `INTEGER PRIMARY KEY` (no natural unique key)
and belong wholly to one parent meeting. On re-fetch, **delete the parent's children, reinsert the
current set**, inside the sync transaction:

```sql
-- transcript_utterances (Fathom → Phase 3). Idempotent per meeting.
DELETE FROM transcript_utterances WHERE meeting_id = :meeting_id;
INSERT INTO transcript_utterances
    (meeting_id, idx, speaker, speaker_email, start_seconds, end_seconds, text)
VALUES
    (:meeting_id, :idx, :speaker, :speaker_email, :start_seconds, :end_seconds, :text);
-- …one INSERT per utterance, ordered by idx.
```

Because transcripts are heavy and rate-limited, **only fetch/replace when the transcript isn't
already stored** (`meetings.has_transcript = 0`) or the provider signals it changed — do not
replace on every poll. `meeting_invitees` follows the same delete-then-insert (populate
`email_domain` — the strong client signal — by lowercasing the part after `@`).

### 7.3 Composite-unique upsert (Slack)

`slack_messages` has `INTEGER PRIMARY KEY` **plus** `UNIQUE(conversation_id, ts)`, so upsert on
the natural key. This makes message **edits** update text and re-polling a boundary `ts`
harmless:

```sql
-- slack_messages (Slack → Phase 4).
INSERT INTO slack_messages
    (conversation_id, conversation_type, conversation_name, ts, posted_at,
     user_id, user_name, is_self, thread_ts, text, permalink, fetched_at)
VALUES
    (:conversation_id, :conversation_type, :conversation_name, :ts, :posted_at,
     :user_id, :user_name, :is_self, :thread_ts, :text, :permalink, :fetched_at)
ON CONFLICT(conversation_id, ts) DO UPDATE SET
    text        = excluded.text,      -- picks up edits
    thread_ts   = excluded.thread_ts,
    permalink   = excluded.permalink,
    fetched_at  = excluded.fetched_at;
```

`posted_at` (epoch seconds) is derived from the Slack `ts` string; `is_self` is set by comparing
`user_id` to the user's own Slack id (resolved once at setup) so phone-sent messages are flagged.

### 7.4 Transactional cursor advance

The UPSERTs for a cycle and the cursor write happen in **one** `syncTransaction` (§3). Example
skeleton for Fathom:

```swift
func sync(_ ctx: SyncContext) async throws -> SyncOutcome {
    let cursor = try await ctx.store.cursor(for: sourceKey)       // last created_after
    let page   = try await client.listMeetings(createdAfter: cursor)  // GET, fixture in tests
    let newCursor = page.meetings.map(\.createdAt).max() ?? cursor
    return try await ctx.store.syncTransaction(source: sourceKey,
                                               newCursor: newCursor) { db in
        for m in page.meetings {
            try upsertMeeting(m, into: db)                        // §7.1
            try replaceInvitees(m, into: db)                     // §7.2
            if m.transcript != nil { try replaceUtterances(m, into: db) } // §7.2, once
        }
        return SyncOutcome(fetched: page.meetings.count,
                           upserted: page.meetings.count,
                           newCursor: newCursor, rateLimited: false)
    }
}
```

---

## 8. Clients are protocols; unit tests use recorded fixtures

Per repo convention ([../../CLAUDE.md](../../CLAUDE.md) Conventions;
[module-map.md](module-map.md#testability)) every external client isolates I/O behind a protocol
so **no unit test touches the network**.

```swift
protocol FathomClient: Sendable {
    func listMeetings(createdAfter: String?) async throws -> FathomMeetingsPage
}

struct LiveFathomClient: FathomClient {   // real URLSession + X-Api-Key from Keychain
    func listMeetings(createdAfter: String?) async throws -> FathomMeetingsPage { … }
}

struct FixtureFathomClient: FathomClient { // returns canned JSON from Tests/Fixtures/
    let page: FathomMeetingsPage
    func listMeetings(createdAfter: String?) async throws -> FathomMeetingsPage { page }
}
```

- Sibling protocols: `ProductiveClient` (GET-only, §2), `CalendarClient`, `SlackClient`.
- **Fixtures** are recorded provider responses under
  `Packages/TidyKit/Tests/TidyIngestTests/Fixtures/<provider>/…json` — **scrubbed of secrets**
  (no tokens, no auth headers; G6) before committing.
- **Source tests** run `sync()` with a `FixtureClient` + an **in-memory GRDB** store and assert:
  the right rows are UPSERTed; a second identical run is a no-op (idempotency); the cursor
  advances only on success; a thrown fetch leaves the cursor and data unchanged; the
  replace-children path removes stale invitees/utterances; a `429` fixture triggers backoff and
  does not advance the cursor.
- **Guardrail tests** (live in the same suite, [../guardrails.md](../guardrails.md)): the
  Productive request builder rejects non-`GET`; the Slack client rejects any method outside the
  read allowlist; the logger/outbound path never emits a token.

---

## 9. File & function manifest (TidyIngest)

Under `Packages/TidyKit/Sources/TidyIngest/` (regenerate the Xcode project with `make generate`
after adding files):

| File | Contents |
|---|---|
| `IngestSource.swift` | `IngestSource`, `SyncContext`, `SyncOutcome`, `IngestError` |
| `IngestCoordinator.swift` | actor scheduler: cadence, jitter, per-source serialization, kill switches, pause |
| `SyncStateStore.swift` | `IngestStore` impl over TidyStore: `cursor(for:)`, `syncTransaction(...)` |
| `HTTP/HTTPClient.swift` | shared async `URLSession` wrapper; per-host method policy (Productive = GET-only) |
| `HTTP/RateLimiter.swift` | per-provider token buckets (Fathom dual bucket) |
| `HTTP/Backoff.swift` | `backoffDelay(...)`, `Retry-After` parsing, retry loop |
| `Productive/ProductiveClient.swift` | protocol (read-only) |
| `Productive/LiveProductiveClient.swift` | JSON:API GETs, `X-Auth-Token`/`X-Organization-Id`, paging |
| `Productive/ProductiveSource.swift` | `IngestSource`; windowed time-entry cursor; §7.1 upserts |
| `Fathom/FathomClient.swift` · `LiveFathomClient.swift` · `FathomSource.swift` | `created_after` cursor; §7.1 + §7.2 |
| `GoogleCalendar/CalendarClient.swift` · `LiveCalendarClient.swift` · `CalendarSource.swift` | `syncToken`; 410→resync; §7.1 (incl. OAuth token refresh via SecretStore) |
| `Slack/SlackClient.swift` · `LiveSlackClient.swift` | read-method allowlist (§2) |
| `Slack/SlackConversationsSource.swift` · `SlackHistorySource.swift` | two-tier scheduling (§5.1); §7.3 |
| `Mapping/*.swift` | provider DTO → GRDB record mappers (domain extraction, `posted_at` from `ts`, etc.) |

Depends on: `TidyCore` (models, `SecretStore`, `Clock`, `TidyLog`), `TidyStore` (DAOs, records).
Depends on **nothing** in `TidyCapture` / `TidyAI` (module-map dependency rule).

---

## 10. Acceptance criteria

A source is done when:

- [ ] Its cache table(s) match what the provider's UI shows for the relevant window (Phase 2
      accept: Productive cache == web app for your week; Phase 3: yesterday's meetings show real
      recorded durations + attendees).
- [ ] A second consecutive `sync()` with no provider changes writes zero new rows and does not
      move the cursor (**idempotent**).
- [ ] After an artificially-failed fetch, the cursor and data are unchanged and `sync_state`
      shows `last_error` populated with `last_success_at` untouched.
- [ ] A `429` fixture drives one backoff and the source recovers on the next tick without a
      duplicate-key crash.
- [ ] The replace-children path (invitees/utterances) removes rows deleted upstream on re-fetch.
- [ ] **G1:** no non-`GET` request can be built for `api.productive.io`; the Slack client refuses
      any non-allowlisted method (guardrail tests green).
- [ ] **G6:** no committed fixture and no log line contains a token or auth header.
- [ ] **G9:** a retention purge of old `slack_messages`/`transcript_utterances` does **not** cause
      them to be re-imported on the next poll (forward-only cursor).
- [ ] All of the above run with **fixtures + in-memory GRDB**, no live network (`make test`).

---

## 11. Gotchas

- **Google refresh-token expiry.** Only avoided by an **Internal**-type OAuth client in the 4Site
  Workspace GCP project (PLAN §5, §10). External/Testing apps expire refresh tokens in 7 days —
  ingest would silently stop. `doctor` must surface a dead Google auth.
- **`syncToken` 410 is normal.** Treat it as "mint a new token", not an error; don't retry-loop.
- **Fathom heavy-call budget.** Never re-pull a transcript you already have; the 30/min heavy
  limit is the real constraint, not the 10-min poll.
- **Slack `Retry-After` is mandatory.** Ignoring it risks the app being throttled harder; the
  limiter must not out-run it.
- **Productive back-dated edits.** A pure `today`-forward cursor misses yesterday's edits — hence
  the trailing 14-day re-sync window for time entries; gap analysis (PLAN §8) depends on it.
- **Deep-link pattern is not in the API** (PLAN §5, §14). Ingest does not synthesize
  `suggestions.deep_link`; the pattern is captured once from the web app into `config.json` and
  applied downstream. ⚠️ Build-time check.
- **`is_self` needs the user's own ids.** Productive `person_id`, Slack user id, and org email are
  resolved once at setup (PLAN §10) and are prerequisites for `pd_people.is_self` /
  `slack_messages.is_self`.
- **Clock injection.** All "now"/window math goes through `SyncContext.clock` so tests are
  deterministic — never call `Date()` directly in a source.

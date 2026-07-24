# Phase 2 — Productive mirror (read-only sync)

Stand up the read-only Productive cache — companies, projects (internal vs. client), your tasks,
your time entries, and your own person id — plus the task deep-link pattern and a menu bar
popover that shows today's logged total.

**Related:** [docs index](../README.md) · [PLAN.md §11 Phase 2](../../PLAN.md) ·
[reference/productive-api.md](../reference/productive-api.md) ·
[architecture/ingest-layer.md](../architecture/ingest-layer.md) ·
[architecture/data-model.md](../architecture/data-model.md) ·
[phase-1-capture.md](phase-1-capture.md) · [phase-3-meetings-calendar.md](phase-3-meetings-calendar.md)

---

## Goal

By the end of Phase 2 the local SQLite cache is a faithful, read-only mirror of *your slice* of
Productive: the `client → project → task` hierarchy and the time you have already logged. This is
the attribution vocabulary every later phase matches against ([understand-layer.md](../architecture/understand-layer.md)
bootstraps `entity_signals` from it) and the "what's already logged" side of gap analysis
([suggestion-engine.md](../architecture/suggestion-engine.md) lands in Phase 5). Phase 2 also
produces the first genuinely useful daily
surface: a menu bar popover showing today's logged total. **Nothing writes to Productive — GET
only, forever** ([G1](../guardrails.md#g1--v1-never-writes-to-productive)).

This phase also lands the **shared ingest plumbing** (`IngestSource`, `IngestCoordinator`, the
`HTTPClient` + rate limiter + backoff) that Phases 3–4 plug into — Productive is the first source,
so it carries the scaffolding ([ingest-layer.md §1](../architecture/ingest-layer.md#1-what-this-layer-does)).

## Scope

### In scope

- `TidyIngest` shared plumbing: `IngestSource` protocol, `IngestCoordinator` actor, `SyncContext`,
  `HTTPClient` (per-host GET-only policy for `api.productive.io`), `RateLimiter`, `Backoff`,
  `SyncStateStore` (cursor helpers over `sync_state`).
- `LiveProductiveClient` (JSON:API GETs) behind the read-only `ProductiveClient` protocol, and
  `ProductiveSource` (windowed cursor, upserts).
- Read-only sync of five resources → five `pd_*` tables: `companies`, `projects`
  (with `project_type_id` internal/client), `tasks` (your assigned), `time_entries` (yours, date-
  windowed), `people` (resolve self).
- **Person-id resolution at setup**: match your email → store `person_id` in `config.json` and set
  `pd_people.is_self = 1`.
- **Task deep-link pattern**: capture the web-app URL shape once, store it in
  `config.productive.task_deep_link_pattern`, and validate it by opening a cached task.
- Menu bar popover: **today's logged total** (a `SUM(time_minutes)` over `pd_time_entries` for
  today), pending-suggestion count placeholder, pause/open-recap stubs.
- `v1-productive` GRDB migration creating the five `pd_*` tables.
- Guardrail test: the Productive request builder rejects any non-`GET` method (G1).
- Fixture-based unit tests for the client, source, upserts, and cursor.

### Out of scope (deferred — do not pull forward)

- **Any write to Productive** — v2 only, a *separate* client ([G1](../guardrails.md#g1--v1-never-writes-to-productive)).
- **Gap analysis** (observed vs. logged reconciliation) — Phase 5
  ([suggestion-engine.md](../architecture/suggestion-engine.md)). Phase 2's popover shows only the
  *logged* number, not an observed-vs-logged delta.
- **`entity_signals` bootstrap** from Productive vocabulary — Phase 3 seeds domains/attendees;
  full keyword bootstrap is Phase 5 ([understand-layer.md §2.2](../architecture/understand-layer.md#22-bootstrap-from-productive-vocabulary-setup--phase-5)).
- **Filling `suggestions.deep_link`** — no `suggestions` table exists until Phase 5; Phase 2 only
  captures and *validates* the URL *pattern*.
- Services/budgets as attribution targets (cached for completeness only; PLAN §2).
- Fathom, Google Calendar, Slack sources (Phases 3–4), though they reuse this phase's plumbing.

## Prerequisites

- **Phase 0** complete: menu bar app, GRDB store + migrator, `config.json` + `SecretStore`
  (Keychain), stable signing ([phase-0-skeleton.md](phase-0-skeleton.md)).
- **Phase 1** complete: `sync_state` table exists (created in Phase 1 so cursors are ready before
  the first source), the migrator pattern, and the `Clock` seam
  ([data-model.md → Capture tables](../architecture/data-model.md#capture-tables-phase-1)).
- **Human setup** ([permissions-setup.md](../permissions-setup.md)):
  1. Productive → **Settings → API integrations → Generate new token**; paste the token — it goes
     to **Keychain only** ([G6](../guardrails.md#g6--secrets-live-in-the-keychain-only)).
  2. `X-Organization-Id` (numeric) into `config.organization.productive_organization_id`
     (non-secret).
  3. During setup, the app resolves and stores your `person_id`.
  4. Open any task in the Productive web app, copy the address-bar URL, confirm/adjust
     `config.productive.task_deep_link_pattern` (⚠️ Build-time check — see [Risks](#risks)).

## Work items (mapped to modules / files)

All ingest files live under `Packages/TidyKit/Sources/TidyIngest/`; run `make generate` after
adding files. See the full manifest in
[ingest-layer.md §9](../architecture/ingest-layer.md#9-file--function-manifest-tidyingest).

### TidyIngest — shared plumbing (lands with this first source)

| File | Contents |
|---|---|
| `IngestSource.swift` | `IngestSource` protocol, `SyncContext`, `SyncOutcome`, `IngestError` ([§3](../architecture/ingest-layer.md#3-the-ingestsource-protocol)) |
| `IngestCoordinator.swift` | actor scheduler: per-source cadence, jitter, per-source serialization, kill switches, pause ([§5](../architecture/ingest-layer.md#5-scheduling--the-coordinator)) |
| `SyncStateStore.swift` | `IngestStore` impl over `TidyStore`: `cursor(for:)`, `syncTransaction(...)` |
| `HTTP/HTTPClient.swift` | async `URLSession` wrapper; **per-host method policy — `api.productive.io` = GET-only** |
| `HTTP/RateLimiter.swift` | per-provider token buckets (Productive: 100/10 s + 4,000/30 min) |
| `HTTP/Backoff.swift` | `backoffDelay(...)`, `Retry-After` parsing, capped full-jitter retry loop |

### TidyIngest — Productive source

| File | Contents |
|---|---|
| `Productive/ProductiveClient.swift` | protocol, **read-only** — no `create/update/delete` method exists |
| `Productive/LiveProductiveClient.swift` | JSON:API GETs; `X-Auth-Token` + `X-Organization-Id` headers; `include`/`fields[]`/`filter[]`/`page[]`; paging loop on `meta` |
| `Productive/ProductiveSource.swift` | `IngestSource`; windowed time-entry cursor; §7.1 upserts; self-resolution |
| `Mapping/ProductiveMappers.swift` | JSON:API DTO → GRDB records (`archived`/`closed` from `*_at` presence; `status` int → `'open'`/`'closed'`) |

Key functions on `ProductiveSource`:

- `resolveSelf()` — `GET /people?filter[email]=<your email>`; on match, upsert `pd_people`
  (`is_self = 1`) and persist `person_id` to config. Runs once at setup, re-checked each sync.
- `syncCompanies()` / `syncProjects()` — bounded full page-walk (small slice); `projects` sideloads
  `company` so the client→project half lands in one request.
- `syncTasks()` — per active project, `filter[project_id]` + `filter[assignee_id]=<person_id>`.
- `syncTimeEntries()` — `filter[person_id]=<person_id>` + `filter[after]`/`filter[before]` over a
  trailing window (default **14 days**) to catch back-dated edits.

### TidyStore

| File | Contents |
|---|---|
| `Migrations/V1Productive.swift` | registers `v1-productive` migration (five `pd_*` tables + indices) |
| `Records/PdCompany.swift` … `PdPerson.swift` | GRDB records mapping 1:1 to the tables |
| `DAO/ProductiveDAO.swift` | upsert helpers, `todaysLoggedMinutes(day:)`, `activeProjects()`, `tasksForProject(_:)` |

### TidyCore

- `Config` additions: read `productive.task_deep_link_pattern`, `productive.sync_interval_seconds`,
  `organization.productive_organization_id`, `organization.productive_person_id`
  (already present in [config.example.json](../../config.example.json)).
- `DeepLink.taskURL(taskId:orgId:pattern:)` — substitute `{org}` / `{task_id}` into the pattern,
  returning a validated `URL`.

### TidySurface

| File | Contents |
|---|---|
| `Popover/MenuBarPopover.swift` | today's logged total (`Xh Ym` from `todaysLoggedMinutes`), sync freshness, pause/open-recap; a **cached-task list** whose rows open the deep link |

### TidyTimeApp

- Setup flow step: paste token (→ Keychain), org id (→ config), run `resolveSelf()`, confirm the
  deep-link pattern by opening a sample cached task.
- Register `ProductiveSource` with the `IngestCoordinator`; wire the popover view model.
- `doctor` view: show Productive `sync_state` (`last_success_at`, `last_error`), resolved
  `person_id`, and row counts per `pd_*` table.

## Data model + migration

Phase 2 creates the **Productive mirror** tables exactly as specified in
[data-model.md → Productive mirror](../architecture/data-model.md#productive-mirror-phase-2-read-only-cache):
`pd_companies`, `pd_projects`, `pd_tasks`, `pd_time_entries`, `pd_people`. **Mirror ids are the
provider's string id (PK), so every sync is an upsert** ([conventions](../architecture/data-model.md#conventions)).

Register a **new** migration; never edit a shipped one
([data-model.md → Migrations](../architecture/data-model.md#migrations)):

```swift
migrator.registerMigration("v1-productive") { db in
    try db.create(table: "pd_companies") { t in
        t.column("id", .text).primaryKey()              // Productive company id
        t.column("name", .text).notNull()
        t.column("company_type", .text)
        t.column("domain", .text)
        t.column("archived", .integer).notNull().defaults(to: 0)
        t.column("synced_at", .integer).notNull()
    }
    try db.create(table: "pd_projects") { t in
        t.column("id", .text).primaryKey()
        t.column("company_id", .text).notNull().references("pd_companies")
        t.column("name", .text).notNull()
        t.column("project_type_id", .integer)           // 1 = internal, 2 = client/deliverable
        t.column("project_number", .text)
        t.column("archived", .integer).notNull().defaults(to: 0)
        t.column("synced_at", .integer).notNull()
    }
    try db.create(table: "pd_tasks") { t in
        t.column("id", .text).primaryKey()
        t.column("project_id", .text).notNull().references("pd_projects")
        t.column("task_list_id", .text)
        t.column("title", .text).notNull()
        t.column("description", .text)
        t.column("task_number", .integer)
        t.column("status", .text)                       // 'open' | 'closed' (mapped from status int)
        t.column("closed", .integer).notNull().defaults(to: 0)
        t.column("assignee_id", .text)
        t.column("due_date", .text)                     // YYYY-MM-DD
        t.column("synced_at", .integer).notNull()
    }
    try db.create(table: "pd_time_entries") { t in
        t.column("id", .text).primaryKey()
        t.column("person_id", .text).notNull()
        t.column("task_id", .text)
        t.column("project_id", .text)
        t.column("service_id", .text)
        t.column("date", .text).notNull()               // YYYY-MM-DD
        t.column("time_minutes", .integer).notNull()    // Productive 'time' — MINUTES
        t.column("billable_minutes", .integer)          // 'billable_time' — MINUTES
        t.column("note", .text)
        t.column("synced_at", .integer).notNull()
    }
    try db.create(table: "pd_people") { t in
        t.column("id", .text).primaryKey()
        t.column("name", .text).notNull()
        t.column("email", .text)
        t.column("is_self", .integer).notNull().defaults(to: 0)
        t.column("synced_at", .integer).notNull()
    }
    try db.create(index: "idx_projects_company",    on: "pd_projects",     columns: ["company_id"])
    try db.create(index: "idx_tasks_project",        on: "pd_tasks",        columns: ["project_id"])
    try db.create(index: "idx_tasks_assignee",       on: "pd_tasks",        columns: ["assignee_id"])
    try db.create(index: "idx_entries_person_date",  on: "pd_time_entries", columns: ["person_id", "date"])
}
```

> **FK ordering note.** Phase 1's `sessions`/`away_gaps` carry `client_id`/`project_id`/`task_id`
> columns whose `REFERENCES pd_*` targets do not exist until now. Per
> [data-model.md → Migrations](../architecture/data-model.md#migrations), Phase 1 declares those FK
> columns **without** the `REFERENCES` clause; do **not** try to add cross-table constraints
> retroactively here (SQLite can't `ALTER` in a FK). Treat them as soft references validated in
> code. Keep `PRAGMA foreign_keys = ON`; the `pd_projects.company_id → pd_companies` FK above is
> intra-phase and safe.

### Upsert & units (the two things people get wrong)

- **String-PK upsert on `id`** ([ingest-layer.md §7.1](../architecture/ingest-layer.md#71-string-pk-upsert-provider-id-is-the-primary-key)):
  archival = mark `archived = 1` (from `archived_at` presence), never hard-delete, so historical
  session FKs stay valid.
- **`time`/`billable_time` are MINUTES** — mirror as `time_minutes`/`billable_minutes`; this is the
  one place TidyTime keeps the API's unit instead of seconds. Do **not** convert
  ([data-model.md conventions](../architecture/data-model.md#conventions),
  [productive-api.md gotchas](../reference/productive-api.md#gotchas)).

### Cursor (`sync_state`, one row, `source = 'productive'`)

Store the last fully-synced day (`YYYY-MM-DD`) as the high-water mark; always re-sync a trailing
14-day window for time entries. Productive has **no `syncToken`** — the timestamp cursor is ours to
manage ([ingest-layer.md §4](../architecture/ingest-layer.md#4-source--cursor-semantics)).

```sql
INSERT INTO sync_state (source, cursor, last_run_at, last_success_at, last_error)
VALUES ('productive', :today, :now, :now, NULL)
ON CONFLICT(source) DO UPDATE SET
    cursor = excluded.cursor, last_run_at = excluded.last_run_at,
    last_success_at = excluded.last_success_at, last_error = NULL;
```

## Key references

- **[reference/productive-api.md](../reference/productive-api.md)** — exact endpoints, headers,
  JSON:API mechanics, per-resource field→column tables, example requests/responses, rate limits,
  and the deep-link section. **This is the ground truth for every request in this phase.**
- [architecture/ingest-layer.md](../architecture/ingest-layer.md) — `IngestSource`, the coordinator,
  cursor semantics, backoff, upsert patterns, and the file/function manifest (§9).
- [architecture/data-model.md](../architecture/data-model.md#productive-mirror-phase-2-read-only-cache)
  — the `pd_*` DDL (canonical column names).
- [guardrails.md](../guardrails.md) — G1 (read-only), G6 (Keychain), G8 (one process).
- [glossary.md](../glossary.md) — Company/Project/Task/Time entry/Person/Deep link definitions.
- [PLAN.md §5 (Productive)](../../PLAN.md) and [§11 Phase 2](../../PLAN.md) — scope & acceptance.

### Request quick-reference (full detail in the reference doc)

| Resource | Table | Filtered by | Sideload |
|---|---|---|---|
| `companies` | `pd_companies` | — (full slice) | — |
| `projects` | `pd_projects` | — (full slice) | `include=company` |
| `tasks` | `pd_tasks` | `project_id` + `assignee_id` | `include=assignee,task_list` |
| `time_entries` | `pd_time_entries` | `person_id` + `filter[after]`/`filter[before]` | `include=task,service` |
| `people` | `pd_people` | `email` (self, once) | — |

```http
GET /api/v2/projects?include=company&fields[project]=name,project_number,project_type_id,archived_at&fields[company]=name&page[size]=200 HTTP/1.1
Host: api.productive.io
X-Auth-Token: {{PRODUCTIVE_TOKEN}}
X-Organization-Id: 42
Content-Type: application/vnd.api+json
```

## Risks

- **Read-only discipline is the whole product (G1).** Enforced architecturally: the
  `ProductiveClient` protocol exposes no mutating method and the shared request builder for
  `api.productive.io` accepts only `HTTPMethod.get`, asserted by a guardrail test that fails loudly
  in `DEBUG`. Read-only token *scoping* is **not** documented by Productive — do not rely on it
  ([productive-api.md auth](../reference/productive-api.md#authentication), ⚠️ Build-time check).
- **⚠️ Build-time check — deep-link pattern.** The task URL is **not in the API**. The likely shape
  is `https://app.productive.io/<org-id>/task/<task_id>`
  ([productive-api.md deep-link](../reference/productive-api.md#deep-link-url-pattern),
  [config default](../../config.example.json)); confirm the real pattern from the web-app address
  bar and store it in `config.json`. The Phase 2 acceptance check (clicking a cached task opens it)
  *is* the verification.
- **⚠️ Build-time checks in field mapping.** Confirm against live payloads:
  `company_type_id` vs. `company_type`; the task `status` enum (`1`=open, `2`=closed);
  `billable_time` is minutes (not hours); the person filter key (`filter[email]`) and whether a
  single `name` attribute exists vs. `first_name`/`last_name`; and that a `time_entry`'s
  `project_id` must be derived via the task/service, not read directly
  ([productive-api.md](../reference/productive-api.md#resources-tidytime-gets--pd_-cache)).
- **`X-Organization-Id` is mandatory** — omitting it returns the wrong org or `401`/`403`, not a
  useful error. Set it on the shared client, not per call.
- **Rate limits** (100/10 s, 4,000/30 min → `429`): a full slice is a handful of requests, far
  under the limits. Use a client-side token bucket + capped full-jitter backoff; persist failures
  to `sync_state.last_error` and let the next cycle recover (the cache is *stale*, not *broken*).
  No `Retry-After`/`RateLimit-*` header is promised — treat any as advisory-if-present.
- **Back-dated edits** — a pure today-forward cursor misses a colleague editing yesterday's entry;
  the trailing 14-day time-entry re-sync window closes this (gap analysis in Phase 5 depends on it).
- **`is_self` needs the resolved `person_id`.** Setup must resolve it before `tasks`/`time_entries`
  can filter; surface an unresolved-self state in `doctor`, don't sync blindly.

## Acceptance criteria (faithful to PLAN §11 Phase 2)

> *"Accept when: the local cache matches what Productive's UI shows for your week, and clicking a
> cached task opens it in Productive."* — [PLAN.md §11](../../PLAN.md)

- [ ] **Cache matches the web app for your week.** After a sync, `pd_companies` / `pd_projects` /
      `pd_tasks` list your active clients, projects (with `project_type_id` distinguishing internal
      `1` from client `2`), and your assigned tasks; `pd_time_entries` for the current week matches
      the entries and durations Productive's UI shows (spot-check totals per day).
- [ ] **Clicking a cached task opens it in Productive.** A task row in the popover / `doctor` view
      opens `DeepLink.taskURL(...)` via `NSWorkspace.open`, landing on that task in the web app —
      proving the captured `task_deep_link_pattern` is correct.
- [ ] **Menu bar popover shows today's logged total.** The popover renders `Xh Ym` =
      `SUM(time_minutes)` over `pd_time_entries WHERE date = today`, and updates after each ~15-min
      sync.
- [ ] **Person-id resolved at setup.** Exactly one `pd_people` row has `is_self = 1`; the same id is
      in `config.organization.productive_person_id` and is the filter used by `tasks`/`time_entries`.
- [ ] **Idempotent re-sync.** A second consecutive `sync()` with no upstream changes writes zero new
      rows and does not move the cursor
      ([ingest-layer.md §10](../architecture/ingest-layer.md#10-acceptance-criteria)).
- [ ] **G1 holds.** No non-`GET` `URLRequest` can be built for `api.productive.io`; the guardrail
      test is green.

## Definition of done

- [ ] `make build` compiles; `make test` passes, including the new fixture-based Productive client /
      source / mapper tests and the **G1 guardrail test** (request builder rejects non-`GET`).
- [ ] `v1-productive` migration is a **new** registered migration (never an edit to a shipped one)
      and [data-model.md](../architecture/data-model.md) already reflects these tables (it does —
      confirm no drift).
- [ ] Token is in **Keychain only**; `config.json` holds org id, `person_id`, deep-link pattern, and
      sync interval — **no secret** in config, DB, logs, or committed fixtures (G6). Fixtures are
      scrubbed of `X-Auth-Token`.
- [ ] The `IngestSource` / `IngestCoordinator` / `HTTPClient` / `RateLimiter` / `Backoff` scaffolding
      is in place and Productive is registered as the first source — Phases 3–4 reuse it unchanged.
- [ ] Deep-link pattern captured and stored; the click-to-open path is wired and verified against a
      real task.
- [ ] `doctor` surfaces Productive `sync_state` (`last_success_at`, `last_error`), the resolved
      `person_id`, and per-`pd_*` row counts.
- [ ] All unit tests run with fixtures + in-memory GRDB — **no live network**.
- [ ] No new lint violation of the prime directives (read-only Productive; no secrets in logs).

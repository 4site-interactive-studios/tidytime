# Productive API (read-only) reference

The JSON:API surface TidyTime GETs to mirror the client → project → task hierarchy and
already-logged time into the local `pd_*` cache. **v1 issues GET only** ([G1](../guardrails.md#g1--v1-never-writes-to-productive)).

**Related:** [docs index](../README.md) · [PLAN.md §5](../../PLAN.md) · [data-model.md](../architecture/data-model.md) ·
[ingest-layer.md](../architecture/ingest-layer.md) · [fathom-api.md](fathom-api.md)

**Status:** stable, read-only client ·
**Base URL:** `https://api.productive.io/api/v2/` ·
**Auth:** `X-Auth-Token` + `X-Organization-Id` (headers) ·
**Source:** <https://developer.productive.io/index.html>,
`/guides/rate-limits.html`, `/guides/pagination.html`, `/guides/filtering.html`,
`/guides/sorting.html`, `/time_entries.html`, `/tasks.html`, `/projects.html`, `/companies.html`, `/people.html` ·
**Last verified:** 2026-07-23

---

## G1 — read-only guarantee (non-negotiable)

TidyTime never mutates Productive in v1. The whole product is "suggest, human enters."

- The `ProductiveClient` protocol in `TidyIngest` (see [module-map.md](../architecture/module-map.md#protocol-seams-the-extension-points))
  exposes **no** `create/update/delete` method — there is no code path that builds a
  `POST`/`PUT`/`PATCH`/`DELETE` `URLRequest` for the `api.productive.io` host.
- A guardrail unit test asserts the request builder aborts on any method other than `GET`
  (fail loudly in `DEBUG`). See [guardrails.md G1](../guardrails.md#g1--v1-never-writes-to-productive).
- "Log it ✓" in the recap flips `suggestions.status` **locally only**; it never calls Productive.
- Write access (v2) will be a **separate** client with its own audited token — never bolted
  onto this one.

---

## Authentication

Two headers on every request. Both are required; a missing `X-Organization-Id` returns the
wrong org's data or `401`/`403`.

| Header | Value | Where it comes from |
|---|---|---|
| `X-Auth-Token` | personal API token | Productive → **Settings → API integrations → Generate new token**. Stored in Keychain only ([G6](../guardrails.md#g6--secrets-live-in-the-keychain-only)). |
| `X-Organization-Id` | numeric org id | Same Settings page / URL of the web app. Non-secret; lives in `config.json`. |
| `Content-Type` | `application/vnd.api+json` | JSON:API media type (send on GET too for consistency). |

⚠️ Build-time check: Productive does not document read-only token scoping, so the read-only
guarantee is **architectural** (G1), not enforced by the token. Do not rely on scope.

```http
GET /api/v2/companies?page[size]=200 HTTP/1.1
Host: api.productive.io
X-Auth-Token: {{PRODUCTIVE_TOKEN}}
X-Organization-Id: 42
Content-Type: application/vnd.api+json
```

---

## JSON:API conventions we rely on

Productive implements the [JSON:API spec](https://jsonapi.org/). The five mechanics TidyTime uses:

1. **Envelope.** Every response is `{ "data": …, "included": [...], "meta": {...}, "links": {...} }`.
   A single resource is an object under `data`; a collection is an array. Each resource is
   `{ "type": "<resource>", "id": "<string>", "attributes": {...}, "relationships": {...} }`.
2. **Relationships + `included` (sideloading).** `?include=company,project` returns related
   resources once in the top-level `included` array; `data[].relationships.<name>.data` gives
   `{type,id}` linkage you resolve against `included`. One request → full hierarchy, no N+1.
3. **Sparse fieldsets.** `?fields[project]=name,project_type_id&fields[company]=name,domain`
   trims each type to the columns we cache — smaller payloads, fewer bytes to sensitivity-screen.
4. **Filtering.** `?filter[<field>]=<value>` (e.g. `filter[project_id]=123`,
   `filter[person_id]=99`). Date ranges use `filter[after]` / `filter[before]`.
   ⚠️ Build-time check: confirm exact filter keys per resource against `/guides/filtering.html`
   with a live call — some resources expose `filter[updated_after]` for incremental pulls.
5. **Sorting.** `?sort=updated_at` (ascending) or `?sort=-updated_at` (descending, `-` prefix).

### Pagination

| Param | Meaning | Default | Max |
|---|---|---|---|
| `page[number]` | 1-based page index | `1` | — |
| `page[size]` | rows per page | `30` | **`200`** |

Read `meta` to drive the loop, then stop when `current_page == total_pages`:

```json
{
  "meta": { "current_page": 1, "total_pages": 1, "total_count": 3,
            "page_size": 200, "max_page_size": 200 },
  "links": { "first": "…page[number]=1…", "last": "…", "next": null, "prev": null }
}
```

TidyTime always requests `page[size]=200`; our slice of the org fits in a handful of pages,
nowhere near the rate limits.

---

## Rate limits & backoff

| Limit | Value | On excess |
|---|---|---|
| Short window | **100 requests / 10 seconds** | `HTTP 429 Too Many Requests` |
| Long window | **4,000 requests / 30 minutes** | `HTTP 429 Too Many Requests` |
| Reports endpoint | 10 requests / 30 seconds | (TidyTime does **not** call reports) |

⚠️ Build-time check: Productive's docs do not promise a `Retry-After` or `RateLimit-*`
header. Treat any such header as advisory-if-present; do not depend on it.

**Backoff strategy** (implement once in the shared ingest client — see
[ingest-layer.md](../architecture/ingest-layer.md)):

- **Client-side token bucket** sized under both windows (≈8 req/s sustained, burst ≤ 100/10s)
  so a full-slice sync never trips 429 in normal operation.
- On `429`: honor `Retry-After` if present, else **exponential backoff with full jitter**
  (base 1 s, cap 60 s), max ~5 attempts, then surface a soft failure and retry next cycle.
- Persist failure to `sync_state.last_error`; a 429 storm never blocks the UI (cache is stale,
  not broken).

```swift
// Pseudocode — the retry lives in the shared HTTP layer, GET-only.
for attempt in 0..<maxAttempts {
    let (data, resp) = try await session.get(request)            // GET only (G1)
    if resp.statusCode == 429 {
        let delay = resp.retryAfter ?? backoff(attempt: attempt)  // full jitter
        try await clock.sleep(for: delay)
        continue
    }
    return try decode(data)
}
```

---

## Resources TidyTime GETs → `pd_*` cache

All five map 1:1 onto the mirror tables in
[data-model.md → Productive mirror](../architecture/data-model.md#productive-mirror-phase-2-read-only-cache).
Mirror ids are the provider's **string** id (PK), so every sync is an **upsert**. Set
`synced_at` = fetch epoch on write.

| Productive resource | Table | Filtered by | Notes |
|---|---|---|---|
| `companies` | `pd_companies` | — (full slice) | clients + internal "companies" |
| `projects` | `pd_projects` | — (full slice) | `project_type_id` 1=internal, 2=client; `company` rel |
| `tasks` | `pd_tasks` | `project_id` + `assignee_id` | your open + recent tasks |
| `time_entries` | `pd_time_entries` | `person_id` + date range | already-logged side of gap analysis |
| `people` | `pd_people` | `email` (self) | resolve your own `person_id` at setup |

---

### companies → `pd_companies`

```http
GET /api/v2/companies?fields[company]=name,domain,company_type_id&page[size]=200 HTTP/1.1
Host: api.productive.io
X-Auth-Token: {{PRODUCTIVE_TOKEN}}
X-Organization-Id: 42
```

```json
{
  "data": [
    {
      "type": "company",
      "id": "512",
      "attributes": {
        "name": "Example Nonprofit",
        "domain": "exampleorg.org",
        "company_type_id": 1,
        "archived_at": null
      }
    },
    {
      "type": "company",
      "id": "513",
      "attributes": {
        "name": "4Site Studios",
        "domain": "4sitestudios.com",
        "company_type_id": 1,
        "archived_at": "2026-01-04T00:00:00Z"
      }
    }
  ],
  "meta": { "current_page": 1, "total_pages": 1, "total_count": 2, "page_size": 200 }
}
```

| JSON:API field | Column ([pd_companies](../architecture/data-model.md#productive-mirror-phase-2-read-only-cache)) | Notes |
|---|---|---|
| `id` | `id` (PK, TEXT) | provider string id |
| `attributes.name` | `name` | |
| `attributes.domain` | `domain` | primary client-domain entity signal |
| `attributes.company_type_id` | `company_type` | store as text if present. ⚠️ Build-time check: confirm attribute name (`company_type_id` vs. `company_type`) on a live company |
| `attributes.archived_at` present | `archived` | `1` when non-null, else `0` |
| — | `synced_at` | fetch epoch |

---

### projects → `pd_projects`

Sideload the company so the client → project half of the hierarchy lands in one request.

```http
GET /api/v2/projects?include=company&fields[project]=name,project_number,project_type_id,archived_at&fields[company]=name&page[size]=200 HTTP/1.1
Host: api.productive.io
X-Auth-Token: {{PRODUCTIVE_TOKEN}}
X-Organization-Id: 42
```

```json
{
  "data": [
    {
      "type": "project",
      "id": "8801",
      "attributes": {
        "name": "Donation Page Redesign",
        "project_number": "P-1042",
        "project_type_id": 2,
        "archived_at": null
      },
      "relationships": {
        "company": { "data": { "type": "company", "id": "512" } }
      }
    }
  ],
  "included": [
    { "type": "company", "id": "512", "attributes": { "name": "Example Nonprofit" } }
  ],
  "meta": { "current_page": 1, "total_pages": 1, "total_count": 1, "page_size": 200 }
}
```

| JSON:API field | Column ([pd_projects](../architecture/data-model.md#productive-mirror-phase-2-read-only-cache)) | Notes |
|---|---|---|
| `id` | `id` (PK) | |
| `relationships.company.data.id` | `company_id` | FK → `pd_companies.id` |
| `attributes.name` | `name` | |
| `attributes.project_type_id` | `project_type_id` | **1 = internal, 2 = client/deliverable** |
| `attributes.project_number` | `project_number` | |
| `attributes.archived_at` present | `archived` | `1`/`0` |
| — | `synced_at` | fetch epoch |

---

### tasks → `pd_tasks`

Filter to your work: your assigned tasks within a project. Combine filters to keep the pull
small (your slice, not the whole org).

```http
GET /api/v2/tasks?filter[project_id]=8801&filter[assignee_id]=99&include=assignee,task_list&fields[task]=title,description,task_number,status,closed_at,due_date&page[size]=200 HTTP/1.1
Host: api.productive.io
X-Auth-Token: {{PRODUCTIVE_TOKEN}}
X-Organization-Id: 42
```

```json
{
  "data": [
    {
      "type": "task",
      "id": "77310",
      "attributes": {
        "title": "Fix ENgrid donation-amount selector",
        "description": "Amount buttons not updating the hidden field on mobile.",
        "task_number": 412,
        "status": 1,
        "closed_at": null,
        "due_date": "2026-07-25"
      },
      "relationships": {
        "project":   { "data": { "type": "project", "id": "8801" } },
        "assignee":  { "data": { "type": "person",  "id": "99" } },
        "task_list": { "data": { "type": "task_list", "id": "3120" } }
      }
    }
  ],
  "included": [
    { "type": "person", "id": "99", "attributes": { "first_name": "Bryan", "last_name": "Casler" } },
    { "type": "task_list", "id": "3120", "attributes": { "name": "Sprint 12" } }
  ],
  "meta": { "current_page": 1, "total_pages": 1, "total_count": 1, "page_size": 200 }
}
```

| JSON:API field | Column ([pd_tasks](../architecture/data-model.md#productive-mirror-phase-2-read-only-cache)) | Notes |
|---|---|---|
| `id` | `id` (PK) | |
| `relationships.project.data.id` | `project_id` | FK → `pd_projects.id` |
| `relationships.task_list.data.id` | `task_list_id` | |
| `attributes.title` | `title` | |
| `attributes.description` | `description` | |
| `attributes.task_number` | `task_number` | |
| `attributes.status` | `status` | map integer → `'open'`/`'closed'`. ⚠️ Build-time check: confirm `status` enum values (`1`=open, `2`=closed) on a live task |
| `attributes.closed_at` present | `closed` | `1`/`0` |
| `relationships.assignee.data.id` | `assignee_id` | filter target |
| `attributes.due_date` | `due_date` | `YYYY-MM-DD` |
| — | `synced_at` | fetch epoch |

---

### time_entries → `pd_time_entries`

The "what's already logged" side of [gap analysis](../glossary.md#attribution-model). Filter to
**you** over a **date range**. Both `time` and `billable_time` are **MINUTES** — mirror them
as-is (do not convert to seconds; see [conventions in data-model.md](../architecture/data-model.md#conventions)).

```http
GET /api/v2/time_entries?filter[person_id]=99&filter[after]=2026-07-20&filter[before]=2026-07-23&include=task,service&fields[time_entry]=time,billable_time,date,note&page[size]=200 HTTP/1.1
Host: api.productive.io
X-Auth-Token: {{PRODUCTIVE_TOKEN}}
X-Organization-Id: 42
```

```json
{
  "data": [
    {
      "type": "time_entry",
      "id": "660145",
      "attributes": {
        "date": "2026-07-22",
        "time": 90,
        "billable_time": 90,
        "note": "ENgrid selector fix + staging QA"
      },
      "relationships": {
        "person":  { "data": { "type": "person",  "id": "99" } },
        "task":    { "data": { "type": "task",    "id": "77310" } },
        "service": { "data": { "type": "service", "id": "20455" } }
      }
    },
    {
      "type": "time_entry",
      "id": "660146",
      "attributes": {
        "date": "2026-07-22",
        "time": 30,
        "billable_time": 0,
        "note": "Weekly internal sync"
      },
      "relationships": {
        "person":  { "data": { "type": "person",  "id": "99" } },
        "task":    { "data": null },
        "service": { "data": { "type": "service", "id": "20460" } }
      }
    }
  ],
  "meta": { "current_page": 1, "total_pages": 1, "total_count": 2, "page_size": 200 }
}
```

| JSON:API field | Column ([pd_time_entries](../architecture/data-model.md#productive-mirror-phase-2-read-only-cache)) | Notes |
|---|---|---|
| `id` | `id` (PK) | |
| `relationships.person.data.id` | `person_id` | filter target (your id) |
| `relationships.task.data.id` | `task_id` | may be `null` (project/service-only entry) |
| `relationships.service.data.id` | `service_id` | budget/service — out of scope for attribution, cached for completeness |
| `attributes.date` | `date` | `YYYY-MM-DD` |
| `attributes.time` | `time_minutes` | **MINUTES** |
| `attributes.billable_time` | `billable_minutes` | **MINUTES**. ⚠️ Build-time check: confirm `billable_time` is minutes (not hours) against one live entry with a known billable duration |
| `attributes.note` | `note` | |
| (derived) | `project_id` | Productive time entries relate to **service**, not project directly; resolve `project_id` via the task's project or the service→project link, else leave `NULL`. ⚠️ Build-time check |
| — | `synced_at` | fetch epoch |

---

### people → `pd_people` (resolve self at setup)

At setup, resolve **your own** `person_id` once by filtering people to your email, then store
it and set `is_self = 1`. Every later sync (`tasks`, `time_entries`) filters on this id.

```http
GET /api/v2/people?filter[email]=bryan.casler@gmail.com&fields[person]=first_name,last_name,email HTTP/1.1
Host: api.productive.io
X-Auth-Token: {{PRODUCTIVE_TOKEN}}
X-Organization-Id: 42
```

```json
{
  "data": [
    {
      "type": "person",
      "id": "99",
      "attributes": {
        "first_name": "Bryan",
        "last_name": "Casler",
        "email": "bryan.casler@gmail.com"
      }
    }
  ],
  "meta": { "current_page": 1, "total_pages": 1, "total_count": 1, "page_size": 30 }
}
```

| JSON:API field | Column ([pd_people](../architecture/data-model.md#productive-mirror-phase-2-read-only-cache)) | Notes |
|---|---|---|
| `id` | `id` (PK) | store as `config.person_id` too |
| `attributes.first_name` + `last_name` | `name` | join with a space |
| `attributes.email` | `email` | |
| (setup match) | `is_self` | `1` for the resolved self row, else `0` |
| — | `synced_at` | fetch epoch |

⚠️ Build-time check: confirm the person filter key (`filter[email]`) and whether a single
`name` attribute exists vs. `first_name`/`last_name` on a live person.

---

## Deep-link URL pattern

⚠️ **Build-time check (Phase 2, one-time).** The web-app URL that opens a task is **not in the
API**. Capture it from any open task in the Productive web app, store the template in
`config.json`, and fill `suggestions.deep_link` from it.

Likely shape (verify before relying):
`https://app.productive.io/<org-id>/task/<task_id>` — grab the real pattern from the browser
address bar in Phase 2 (see [PLAN.md §14 item 2](../../PLAN.md)).

---

## Incremental sync & cursors

- **Cadence:** full-slice refresh every **~15 minutes** (PLAN §5). A complete pull of your
  companies, projects, your tasks, your recent time entries, and self is a handful of paged
  requests — far under the rate limits.
- **Cursor home:** `sync_state` (one row, `source = 'productive'`) — see
  [data-model.md → sync_state](../architecture/data-model.md#capture-tables-phase-1).
  Store the last successful sync epoch in `cursor`; set `last_run_at` / `last_success_at`;
  record 429/other failures in `last_error`.
- **Narrowing (optional):** for high-churn resources, pass `filter[after]` (time_entries) or a
  resource's `filter[updated_after]` where supported to fetch only changed rows since `cursor`;
  otherwise a bounded full refresh is simplest and cheap. Productive has **no `syncToken`**
  (unlike Google Calendar) — the timestamp cursor is ours to manage.
- Every write to `pd_*` is an **upsert on the provider id PK**; deletions/archival are handled
  by re-reading `archived_at`/`closed_at`, not by row removal.

```sql
-- After a successful Productive sync cycle:
INSERT INTO sync_state (source, cursor, last_run_at, last_success_at, last_error)
VALUES ('productive', :now_epoch, :now_epoch, :now_epoch, NULL)
ON CONFLICT(source) DO UPDATE SET
    cursor          = excluded.cursor,
    last_run_at     = excluded.last_run_at,
    last_success_at = excluded.last_success_at,
    last_error      = NULL;
```

---

## Gotchas

- **`X-Organization-Id` is mandatory.** Omitting it does not error usefully; it returns
  nothing or the wrong org. Set it on the shared client, not per call.
- **`included` is deduplicated.** A resource referenced by many parents appears **once** in
  `included`; resolve `{type,id}` against a map, don't assume positional order.
- **Relationship data can be `null`** (e.g. a `time_entry` with no `task`). Guard before
  dereferencing `.data.id`.
- **Units are minutes** in `pd_time_entries` (`time_minutes`, `billable_minutes`) — the one
  place TidyTime mirrors the API's unit instead of storing seconds. Do not "helpfully" convert.
- **`archived`/`closed` come from timestamp presence** (`archived_at`, `closed_at`), not a
  boolean attribute — map non-null → `1`.
- **No write endpoints exist in this client, by design (G1).** If you find yourself needing a
  `POST`, you are building v2 — stop and design write scope + audit properly.

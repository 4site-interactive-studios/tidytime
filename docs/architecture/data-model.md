# Data model

**Status:** canonical (this file is the single source of truth for table & column names) ·
**Store:** SQLite via GRDB, WAL mode, `~/Library/Application Support/TidyTime/tidytime.sqlite` ·
**Last reviewed:** 2026-07-23

Every other doc references these names; if you rename a column, rename it here first. The DDL
below is the **v1 baseline**. Changes after a phase ships are **new migrations**, never edits
to a shipped one — see [Migrations](#migrations).

## Conventions

- **Timestamps:** `INTEGER` Unix epoch **seconds, UTC**. Column names end in `_at` (a point in
  time) or `_start` / `_end` (interval bounds). Never store local wall-clock without the zone.
- **Durations:** `INTEGER` **seconds** in our own tables. Exception: Productive mirror tables
  keep the API's units — `time_minutes`, `billable_minutes` are **minutes**.
- **Local ids:** `INTEGER PRIMARY KEY` (SQLite rowid alias). **Mirror ids:** the provider's
  **string** id is the PK (`pd_*`, `meetings`, `calendar_events`), so re-sync is an upsert.
- **Booleans:** `INTEGER` `0`/`1`.
- **Days:** `TEXT` `YYYY-MM-DD` in the user's configured local zone (the unit the recap and
  Productive both think in).
- **JSON columns:** `TEXT` holding compact JSON; used only where the shape is peripheral to
  querying (attendee lists, source refs, per-client rollups).
- **PRAGMAs at open:** `foreign_keys = ON`, `journal_mode = WAL`, `busy_timeout = 5000`.
- GRDB record types map **1:1** to these tables (`Codable` + `FetchableRecord`,
  `MutablePersistableRecord`). Table name = snake_case; Swift type = PascalCase singular
  (`activity_samples` → `ActivitySample`).

## Which phase creates what

| Tables | Phase |
|---|---|
| `activity_samples`, `page_snapshots`, `sessions`, `away_gaps`, `sync_state` | 1 |
| `pd_companies`, `pd_projects`, `pd_tasks`, `pd_time_entries`, `pd_people` | 2 |
| `meetings`, `meeting_invitees`, `transcript_utterances`, `calendar_events` | 3 |
| `slack_messages` | 4 |
| `entity_signals`, `suggestions`, `decisions`, `pools`, `resolution_questions`, `daily_rollups` | 5 |
| `ai_calls`, `nudges` | 6 |

---

## Capture tables (Phase 1)

```sql
CREATE TABLE activity_samples (
    id            INTEGER PRIMARY KEY,
    started_at    INTEGER NOT NULL,          -- context became frontmost
    ended_at      INTEGER,                   -- superseded by next sample (NULL = current)
    app_bundle_id TEXT    NOT NULL,
    app_name      TEXT    NOT NULL,
    window_title  TEXT,
    is_browser    INTEGER NOT NULL DEFAULT 0,
    browser       TEXT,                       -- 'chrome' in v1
    url           TEXT,                        -- active tab URL when is_browser
    source        TEXT    NOT NULL,            -- 'switch' | 'heartbeat'
    created_at    INTEGER NOT NULL
);
CREATE INDEX idx_samples_started ON activity_samples(started_at);
CREATE INDEX idx_samples_app     ON activity_samples(app_bundle_id);

CREATE TABLE page_snapshots (
    id           INTEGER PRIMARY KEY,
    sample_id    INTEGER NOT NULL REFERENCES activity_samples(id) ON DELETE CASCADE,
    captured_at  INTEGER NOT NULL,
    url          TEXT    NOT NULL,
    title        TEXT,
    content_hash TEXT    NOT NULL,             -- sha256 of text; skip re-store on match
    text         TEXT    NOT NULL,             -- document.body.innerText, truncated ~4 KB
    text_bytes   INTEGER NOT NULL
);
CREATE INDEX idx_snapshots_sample ON page_snapshots(sample_id);
CREATE INDEX idx_snapshots_hash   ON page_snapshots(content_hash);

CREATE TABLE sessions (
    id               INTEGER PRIMARY KEY,
    kind             TEXT    NOT NULL,          -- 'screen' | 'meeting' | 'slack'
    started_at       INTEGER NOT NULL,
    ended_at         INTEGER NOT NULL,
    duration_seconds INTEGER NOT NULL,
    title            TEXT,                       -- human label
    context_key      TEXT,                       -- normalized dominant signal (host/channel/…)
    primary_app      TEXT,
    source_ref       TEXT,                       -- meeting id / slack conversation id / NULL
    -- resolved attribution (nullable until classified):
    client_id        TEXT REFERENCES pd_companies(id),
    project_id       TEXT REFERENCES pd_projects(id),
    task_id          TEXT REFERENCES pd_tasks(id),
    confidence       REAL,
    produced_by_rung INTEGER,                    -- 1..5, which ladder rung classified it
    rationale        TEXT,                        -- "matched EN account 'exampleorg'"
    is_sensitive     INTEGER NOT NULL DEFAULT 0,
    classified_at    INTEGER,
    created_at       INTEGER NOT NULL
);
CREATE INDEX idx_sessions_started ON sessions(started_at);
CREATE INDEX idx_sessions_client  ON sessions(client_id);

CREATE TABLE away_gaps (
    id               INTEGER PRIMARY KEY,
    started_at       INTEGER NOT NULL,
    ended_at         INTEGER NOT NULL,
    duration_seconds INTEGER NOT NULL,
    cause            TEXT    NOT NULL,          -- 'idle' | 'lock' | 'sleep'
    attribution      TEXT,                       -- 'break' | 'call' | 'other' (from away prompt)
    note             TEXT,
    client_id        TEXT REFERENCES pd_companies(id),
    project_id       TEXT REFERENCES pd_projects(id),
    resolved_at      INTEGER,
    created_at       INTEGER NOT NULL
);
CREATE INDEX idx_away_started ON away_gaps(started_at);

-- Incremental-sync cursors for every ingest source (one row per source).
CREATE TABLE sync_state (
    source          TEXT PRIMARY KEY,           -- 'productive' | 'fathom' | 'google_calendar' | 'slack:<conv>'
    cursor          TEXT,                        -- syncToken / created_after / latest ts
    last_run_at     INTEGER,
    last_success_at INTEGER,
    last_error      TEXT
);
```

## Productive mirror (Phase 2, read-only cache)

```sql
CREATE TABLE pd_companies (
    id           TEXT PRIMARY KEY,              -- Productive company id
    name         TEXT NOT NULL,
    company_type TEXT,                           -- if exposed
    domain       TEXT,                           -- primary domain if available
    archived     INTEGER NOT NULL DEFAULT 0,
    synced_at    INTEGER NOT NULL
);

CREATE TABLE pd_projects (
    id              TEXT PRIMARY KEY,
    company_id      TEXT NOT NULL REFERENCES pd_companies(id),
    name            TEXT NOT NULL,
    project_type_id INTEGER,                     -- 1 = internal, 2 = client/deliverable
    project_number  TEXT,
    archived        INTEGER NOT NULL DEFAULT 0,
    synced_at       INTEGER NOT NULL
);
CREATE INDEX idx_projects_company ON pd_projects(company_id);

CREATE TABLE pd_tasks (
    id           TEXT PRIMARY KEY,
    project_id   TEXT NOT NULL REFERENCES pd_projects(id),
    task_list_id TEXT,
    title        TEXT NOT NULL,
    description  TEXT,
    task_number  INTEGER,
    status       TEXT,                            -- 'open' | 'closed' (mapped from status_id)
    closed       INTEGER NOT NULL DEFAULT 0,
    assignee_id  TEXT,
    due_date     TEXT,                            -- YYYY-MM-DD
    synced_at    INTEGER NOT NULL
);
CREATE INDEX idx_tasks_project  ON pd_tasks(project_id);
CREATE INDEX idx_tasks_assignee ON pd_tasks(assignee_id);

CREATE TABLE pd_time_entries (
    id               TEXT PRIMARY KEY,
    person_id        TEXT NOT NULL,
    task_id          TEXT,
    project_id       TEXT,
    service_id       TEXT,
    date             TEXT NOT NULL,               -- YYYY-MM-DD
    time_minutes     INTEGER NOT NULL,            -- Productive 'time' (minutes)
    billable_minutes INTEGER,                     -- 'billable_time' (minutes)
    note             TEXT,
    synced_at        INTEGER NOT NULL
);
CREATE INDEX idx_entries_person_date ON pd_time_entries(person_id, date);

CREATE TABLE pd_people (
    id        TEXT PRIMARY KEY,
    name      TEXT NOT NULL,
    email     TEXT,
    is_self   INTEGER NOT NULL DEFAULT 0,         -- the user's own person row
    synced_at INTEGER NOT NULL
);
```

## Meetings & calendar (Phase 3)

```sql
CREATE TABLE meetings (
    id                TEXT PRIMARY KEY,           -- Fathom meeting id (or 'cal:<eventid>' fallback)
    source            TEXT NOT NULL,              -- 'fathom' | 'calendar'
    title             TEXT,
    scheduled_start   INTEGER,
    scheduled_end     INTEGER,
    recording_start   INTEGER,                    -- ground truth for duration
    recording_end     INTEGER,
    duration_seconds  INTEGER NOT NULL,           -- recording span if present, else scheduled
    has_transcript    INTEGER NOT NULL DEFAULT 0,
    has_summary       INTEGER NOT NULL DEFAULT 0,
    summary           TEXT,
    external_url      TEXT,                        -- Fathom share URL
    calendar_event_id TEXT REFERENCES calendar_events(id),
    fetched_at        INTEGER NOT NULL,
    created_at        INTEGER NOT NULL
);

CREATE TABLE meeting_invitees (
    id           INTEGER PRIMARY KEY,
    meeting_id   TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    email        TEXT,
    name         TEXT,
    email_domain TEXT,                             -- strong client signal
    is_external  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_invitees_meeting ON meeting_invitees(meeting_id);
CREATE INDEX idx_invitees_domain  ON meeting_invitees(email_domain);

CREATE TABLE transcript_utterances (
    id            INTEGER PRIMARY KEY,
    meeting_id    TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    idx           INTEGER NOT NULL,               -- order within transcript
    speaker       TEXT,
    speaker_email TEXT,
    start_seconds REAL NOT NULL,                  -- offset from recording_start
    end_seconds   REAL,
    text          TEXT NOT NULL
);
CREATE INDEX idx_utterances_meeting ON transcript_utterances(meeting_id, idx);

CREATE TABLE calendar_events (
    id              TEXT PRIMARY KEY,             -- Google event id
    calendar_id     TEXT NOT NULL,
    title           TEXT,
    description     TEXT,
    location        TEXT,
    start_at        INTEGER NOT NULL,
    end_at          INTEGER NOT NULL,
    all_day         INTEGER NOT NULL DEFAULT 0,
    status          TEXT,                          -- 'confirmed' | 'tentative' | 'cancelled'
    organizer_email TEXT,
    attendees_json  TEXT,                          -- [{email,name,responseStatus,is_external}]
    conference_url  TEXT,                          -- Meet/Zoom link
    ical_uid        TEXT,
    updated_at      INTEGER,                       -- event's own updated stamp
    fetched_at      INTEGER NOT NULL
);
CREATE INDEX idx_events_start ON calendar_events(start_at);
```

## Slack (Phase 4)

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
CREATE INDEX idx_slack_posted ON slack_messages(posted_at);
CREATE INDEX idx_slack_conv   ON slack_messages(conversation_id);
```

## Understand & suggest (Phase 5)

```sql
CREATE TABLE entity_signals (
    id           INTEGER PRIMARY KEY,
    signal_type  TEXT NOT NULL,                  -- 'email_domain'|'slack_channel'|'staging_url'|
                                                 -- 'url_host'|'en_account'|'person_email'|
                                                 -- 'keyword'|'meeting_title'
    signal_value TEXT NOT NULL,                  -- normalized (lowercased host, channel id, …)
    client_id    TEXT REFERENCES pd_companies(id),
    project_id   TEXT REFERENCES pd_projects(id),
    provenance   TEXT NOT NULL,                  -- 'bootstrapped'|'inferred'|'user_confirmed'
    weight       REAL NOT NULL DEFAULT 1.0,
    hit_count    INTEGER NOT NULL DEFAULT 0,
    last_seen_at INTEGER,
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL,
    UNIQUE(signal_type, signal_value)
);
CREATE INDEX idx_signals_value ON entity_signals(signal_value);

CREATE TABLE pools (
    id                 INTEGER PRIMARY KEY,
    day                TEXT NOT NULL,             -- YYYY-MM-DD
    client_id          TEXT REFERENCES pd_companies(id),
    project_id         TEXT REFERENCES pd_projects(id),
    accumulated_seconds INTEGER NOT NULL DEFAULT 0,
    item_count         INTEGER NOT NULL DEFAULT 0,
    items_json         TEXT NOT NULL DEFAULT '[]',-- [{session_id,seconds,blurb}]
    status             TEXT NOT NULL DEFAULT 'open', -- 'open'|'rolled_up'|'suggested'
    suggestion_id      INTEGER REFERENCES suggestions(id),
    created_at         INTEGER NOT NULL,
    updated_at         INTEGER NOT NULL
);
CREATE INDEX idx_pools_day ON pools(day);

CREATE TABLE suggestions (
    id                        INTEGER PRIMARY KEY,
    day                       TEXT NOT NULL,       -- YYYY-MM-DD the entry is for
    kind                      TEXT NOT NULL,       -- 'session'|'pool'|'meeting_segment'|'away'|'new_task'
    client_id                 TEXT REFERENCES pd_companies(id),
    project_id                TEXT REFERENCES pd_projects(id),
    task_id                   TEXT REFERENCES pd_tasks(id),
    proposed_task_title       TEXT,                -- for kind='new_task'
    proposed_task_description TEXT,
    minutes                   INTEGER NOT NULL,    -- rounded to 15-min increments
    raw_seconds               INTEGER NOT NULL,    -- observed, pre-rounding
    billable                  INTEGER,             -- inferred billable flag (0/1/NULL)
    note                      TEXT,
    confidence                REAL NOT NULL,
    produced_by_rung          INTEGER NOT NULL,    -- 1..5
    rationale                 TEXT,
    is_rounded_up             INTEGER NOT NULL DEFAULT 0,
    is_sensitive              INTEGER NOT NULL DEFAULT 0,
    deep_link                 TEXT,                -- Productive task URL
    status                    TEXT NOT NULL DEFAULT 'pending',
                                                   -- 'pending'|'logged'|'edited'|'reassigned'|'tossed'|'snoozed'
    source_refs_json          TEXT NOT NULL,       -- {sessions:[…]} | {pool_id} | {meeting_id,seg} | {away_id}
    created_at                INTEGER NOT NULL,
    updated_at                INTEGER NOT NULL
);
CREATE INDEX idx_suggestions_day ON suggestions(day, status);

CREATE TABLE decisions (
    id            INTEGER PRIMARY KEY,
    suggestion_id INTEGER REFERENCES suggestions(id),
    action        TEXT NOT NULL,                  -- 'accept'|'edit'|'reassign'|'toss'|'log'|'snooze'
    before_json   TEXT,                            -- suggestion snapshot before the action
    after_json    TEXT,                            -- snapshot after edit/reassign
    client_id     TEXT,
    project_id    TEXT,
    task_id       TEXT,
    note          TEXT,
    created_at    INTEGER NOT NULL
);
CREATE INDEX idx_decisions_created ON decisions(created_at);

CREATE TABLE resolution_questions (
    id                INTEGER PRIMARY KEY,
    question          TEXT NOT NULL,              -- "Which client is staging.example.org?"
    signal_type       TEXT NOT NULL,
    signal_value      TEXT NOT NULL,
    status            TEXT NOT NULL DEFAULT 'open',-- 'open'|'answered'|'dismissed'
    answer_client_id  TEXT REFERENCES pd_companies(id),
    answer_project_id TEXT REFERENCES pd_projects(id),
    created_at        INTEGER NOT NULL,
    answered_at       INTEGER,
    UNIQUE(signal_type, signal_value)
);

CREATE TABLE daily_rollups (
    id                INTEGER PRIMARY KEY,
    day               TEXT NOT NULL UNIQUE,
    observed_seconds  INTEGER NOT NULL DEFAULT 0,
    attributed_seconds INTEGER NOT NULL DEFAULT 0,
    logged_minutes    INTEGER NOT NULL DEFAULT 0,
    billable_minutes  INTEGER NOT NULL DEFAULT 0,
    internal_minutes  INTEGER NOT NULL DEFAULT 0,
    per_client_json   TEXT NOT NULL DEFAULT '{}',
    capture_health    REAL,                        -- attributed / observed
    ai_cost_usd       REAL NOT NULL DEFAULT 0,
    -- Added post-v1 by the `v2-context-switches` migration (see Migrations below):
    context_switches      INTEGER NOT NULL DEFAULT 0,  -- distinct-context transitions that day
    brief_switches        INTEGER NOT NULL DEFAULT 0,  -- transitions with dwell < 2 min (thrash)
    longest_focus_seconds INTEGER NOT NULL DEFAULT 0,  -- longest uninterrupted attended run
    created_at        INTEGER NOT NULL,
    updated_at        INTEGER NOT NULL
);
```

The three context-switch columns are computed from the **raw `activity_samples` stream** (not from
`sessions`), so sub-minute thrash still counts even though sessionization filters it. Unattended time
is clipped out via `away_gaps` before the metric is computed — see
[`ContextSwitchAnalyzer`](../../Packages/TidyKit/Sources/TidyStore/ContextSwitch.swift).

## AI ledger & nudges (Phase 6)

```sql
CREATE TABLE ai_calls (
    id            INTEGER PRIMARY KEY,
    occurred_at   INTEGER NOT NULL,
    job_type      TEXT NOT NULL,                  -- 'session_batch'|'transcript_split'|'note_draft'|
                                                  -- 'calibration'|'escalation'|'on_device_classify'
    provider      TEXT NOT NULL,                  -- 'apple'|'fireworks'|'anthropic'
    model         TEXT NOT NULL,
    input_tokens  INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    cost_usd      REAL NOT NULL DEFAULT 0,        -- from the config price table
    latency_ms    INTEGER,
    outcome       TEXT NOT NULL,                  -- 'ok'|'retried'|'escalated'|'error'|
                                                  -- 'refused_budget'|'refused_sensitive'
    request_ref   TEXT,                            -- what it classified (session ids / meeting id)
    error         TEXT
);
CREATE INDEX idx_aicalls_occurred ON ai_calls(occurred_at);
CREATE INDEX idx_aicalls_provider ON ai_calls(provider, model);

CREATE TABLE nudges (
    id            INTEGER PRIMARY KEY,
    fired_at      INTEGER NOT NULL,
    context_key   TEXT NOT NULL,
    client_id     TEXT REFERENCES pd_companies(id),
    session_id    INTEGER REFERENCES sessions(id),
    suggestion_id INTEGER REFERENCES suggestions(id),
    outcome       TEXT,                            -- 'accepted'|'snoozed'|'dismissed'|'ignored'
    responded_at  INTEGER
);
CREATE INDEX idx_nudges_fired   ON nudges(fired_at);
CREATE INDEX idx_nudges_context ON nudges(context_key);
```

## Migrations

Use GRDB's `DatabaseMigrator`. **One registered migration per schema change, applied in
order, and never edited once shipped** — a shipped migration is immutable history; corrections
are a new migration.

### Registered migrations (as shipped)

Authoritative list — mirrors
[`Migrations.swift`](../../Packages/TidyKit/Sources/TidyStore/Migrations.swift), in order:

| # | Identifier | Phase | Creates / changes |
|---|---|---|---|
| 1 | `v1-core` | 0 | `app_metadata` |
| 2 | `v1-capture` | 1 | `activity_samples`, `page_snapshots`, `sessions`, `away_gaps`, `sync_state` |
| 3 | `v1-productive` | 2 | `pd_companies`, `pd_projects`, `pd_tasks`, `pd_time_entries`, `pd_people` |
| 4 | `v1-meetings` | 3 | `calendar_events`, `meetings`, `meeting_invitees`, `transcript_utterances` |
| 5 | `v1-slack` | 4 | `slack_messages` |
| 6 | `v1-understand` | 5 | `entity_signals`, `pools`, `suggestions`, `decisions`, `resolution_questions`, `daily_rollups` |
| 7 | `v1-ai` | 6 | `ai_calls`, `nudges` |
| 8 | `v2-context-switches` | post-v1 | adds 3 context-switch columns to `daily_rollups` |
| 9 | `v2-page-snapshot-time-index` | post-v1 | index on `page_snapshots(captured_at)` |

Migrations 8–9 are **additive and safe on a populated database** (new columns are `NOT NULL` with
defaults); the upgrade path is covered by `MigrationUpgradePathTests`.

```swift
var migrator = DatabaseMigrator()
migrator.registerMigration("v1-baseline") { db in
    // CREATE TABLE statements for the phase's tables (grouped per the phase map above,
    // or split into per-phase migrations v1a…v1f if you prefer smaller units).
}
```

Practical guidance:
- It is fine to grow the baseline across phases as separate migrations (`v1-capture`,
  `v1-productive`, …) so each phase's PR carries its own migration.
- In `DEBUG`, `migrator.eraseDatabaseOnSchemaChange = true` speeds iteration; **never** in
  release.
- Foreign keys reference tables that a later phase creates (`sessions.client_id` →
  `pd_companies`). Order migrations so referenced tables exist first, or add the FK columns
  without the `REFERENCES` clause in Phase 1 and introduce the constraint when the target
  table lands. The DDL above shows the intended final shape.

## Retention (Phase 1 job, enforced ongoing — guardrail G9)

A scheduled job deletes rows older than the configured window (default **90 days**) from the
high-volume/sensitive tables; distilled artifacts persist forever.

| Purged after retention window | Kept indefinitely |
|---|---|
| `activity_samples`, `page_snapshots` | `sessions`, `suggestions`, `decisions` |
| `slack_messages` | `daily_rollups`, `entity_signals` |
| `transcript_utterances` (keep `meetings` summary rows) | `pools` (metadata), `ai_calls` |

`page_snapshots` cascade-delete with their `activity_samples`; `transcript_utterances`
cascade with a purged meeting only if the meeting itself ages out — by default we keep the
`meetings` summary row and drop only utterances past the window. Retention windows are
per-table configurable in `config.json`.

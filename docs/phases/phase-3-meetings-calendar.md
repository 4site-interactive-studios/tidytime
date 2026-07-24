# Phase 3 — Meetings & calendar (Fathom + Google)

Add the two meeting sources — Google Calendar (read-only OAuth, Internal type) and Fathom
(polling with transcripts) — build meeting sessions on Fathom-true recorded durations, ship the
away prompt, and land the attendee-domain bootstrap inputs for entity resolution.

**Related:** [docs index](../README.md) · [PLAN.md §11 Phase 3](../../PLAN.md) ·
[reference/fathom-api.md](../reference/fathom-api.md) ·
[reference/google-calendar-api.md](../reference/google-calendar-api.md) ·
[architecture/ingest-layer.md](../architecture/ingest-layer.md) ·
[phase-2-productive.md](phase-2-productive.md) · [phase-4-slack.md](phase-4-slack.md)

---

## Status: as built (2026-07-23)

> ✅ **Logic complete + unit-tested** (72 tests total). Shipped: `v1-meetings` migration + records/
> DAOs, `TimeParse`, the Fathom client/mapper/sync (`MeetingSessionBuilder`, recording-span
> duration, idempotent re-sync), the Google Calendar client/mapper/sync (camelCase, cancelled →
> delete, `is_external` via `internal_domains`, `syncToken` cursor), and away-gap resolution. OAuth
> access-token exchange is behind an injected provider seam. Full write-up:
> [../retrospectives/phase-3.md](../retrospectives/phase-3.md).
>
> ⚠️ **Manual/build-time checks:** Fathom API access + exact response shape; the Google Internal-type
> OAuth loopback+PKCE flow and refresh-token longevity; meetings appearing with real durations
> end-to-end. `meetings.calendar_event_id` is left NULL until a later time+attendee match.

## Goal

After Phase 3, **yesterday's meetings appear with real recorded durations and attendees**, and
**returning from a long gap prompts you** to say what it was. Concretely:

- Google Calendar sync (read-only, `calendar.readonly`, Internal-type OAuth) mirrors the day's
  events, attendees, and conference links into `calendar_events`.
- Fathom polling mirrors recorded meetings, their invitees, and speaker-labeled transcripts into
  `meetings` / `meeting_invitees` / `transcript_utterances`, with **`recording_start`/
  `recording_end` as ground truth for duration** (PLAN §5, §8).
- Meeting `sessions` (`kind = 'meeting'`) are materialized from `meetings` (not screen samples),
  carrying the Fathom-true `duration_seconds`
  ([understand-layer.md §1.3](../architecture/understand-layer.md#13-meeting--slack-sessions-from-ingest-not-screen-samples)).
- The **away prompt** turns a Phase-1-detected `away_gaps` row into an answered attribution
  (break / call+who / other).
- Attendee/invitee **domains** are parsed and `is_external`-derived — the raw material that (with
  Phase 2's `pd_companies.domain`) bootstraps entity resolution.

This phase reuses the ingest plumbing (`IngestSource`, `IngestCoordinator`, `HTTPClient`,
`RateLimiter`, `Backoff`, `SyncStateStore`) that **Phase 2 already landed**
([ingest-layer.md §1](../architecture/ingest-layer.md#1-what-this-layer-does)) — both sources are
new `IngestSource` conformers, nothing in the coordinator changes.

## Scope

### In scope

- **Google OAuth** (`TidyIngest/GoogleCalendar/GoogleOAuth`): loopback (127.0.0.1) + PKCE desktop
  flow, refresh-token persistence to Keychain, proactive/reactive token refresh, `invalid_grant`
  re-auth path. Client created as **Internal** user type in the 4Site Workspace GCP project.
- **Calendar sync** (`CalendarSource`): `events.list` initial windowed sync + `syncToken`
  incremental, `410 GONE` full-resync, Meet/Zoom `conference_url` resolution, `is_external`
  derivation, cancellations as `status = 'cancelled'`.
- **Fathom sync** (`FathomSource`): `GET /meetings?include_transcript=true&include_summary=true`,
  `created_after` cursor, heavy-call rate discipline, upsert meetings + replace-children invitees/
  utterances, `duration_seconds` from the recording span.
- **Meeting sessions**: `TidyUnderstand` builds one `sessions` row (`kind = 'meeting'`,
  `source_ref = meetings.id`) per meeting with Fathom-true duration; screen activity during a
  meeting window is labeled in-meeting context, not separate work.
- **Fathom ⇄ Calendar reconciliation**: match by `ical_uid` / time-window + attendee overlap; on a
  match, Fathom supplies duration and `meetings.calendar_event_id` links back; a confirmed timed
  event with no Fathom match becomes a calendar-only meeting (`id = 'cal:<eventid>'`,
  `source = 'calendar'`).
- **Away prompt** (`TidySurface`): on return from an `away_gaps` interval, ask break/call/other and
  write the answer back to `away_gaps` (`attribution`, `note`, `client_id`, `project_id`,
  `resolved_at`).
- **Entity-signal bootstrap inputs**: parse `email_domain`, derive `is_external`; make the
  attendee/invitee + Productive-domain signals available for entity resolution (see the
  [entity_signals ordering note](#entity-signal-bootstrap-inputs) — the table itself lands in Phase 5).
- `v1-meetings` GRDB migration (four tables).
- Fixture-based tests for both sources, the OAuth token unit, reconciliation, and the away prompt.

### Out of scope (deferred — do not pull forward)

- **Meeting *splitting*** into per-client transcript segments — that is ladder rung 4 + the
  suggestion engine ([suggestion-engine.md](../architecture/suggestion-engine.md)), Phase 5–6.
  Phase 3 materializes the meeting session and stores the transcript; it does **not** classify it.
- **Classifying** meeting/calendar sessions to a client — Phase 5 (rules/lexical) onward.
- **The `entity_signals` table and minting bootstrapped rows** — created in Phase 5 per the
  [data-model.md phase map](../architecture/data-model.md#which-phase-creates-what). Phase 3 lands
  the *inputs* only.
- **`suggestions` from away answers** — no `suggestions` table until Phase 5; a "call" answer is
  recorded on `away_gaps` and *becomes* a suggestion later. Unanswered prompts queue to the recap
  (Phase 5).
- **Fathom webhook** — v1 polls; the webhook is a post-v1 upgrade
  ([fathom-api.md webhook](../reference/fathom-api.md#webhook-later-upgrade-not-v1)).
- Slack (Phase 4); multi-calendar / `calendarList.list` (later); CoreAudio mic detection (later).

## Prerequisites

- **Phase 2** complete: the ingest plumbing (coordinator, `HTTPClient`, backoff, `SyncStateStore`)
  and the `pd_*` cache — `pd_companies.domain` is a bootstrap input; `pd_people`/`pd_projects` are
  needed for the away prompt's client/project picker.
- **`away_gaps` exists (Phase 1)** and is populated by idle/lock/sleep detection
  ([data-model.md → Capture tables](../architecture/data-model.md#capture-tables-phase-1)); Phase 3
  adds only the prompt that *answers* those rows.
- **`sync_state` exists (Phase 1)**; add rows for `source = 'fathom'` and
  `source = 'google_calendar'`.
- **Human setup** ([permissions-setup.md](../permissions-setup.md), PLAN §10):
  1. **Google**: create an **Internal**-type OAuth client (Desktop app) in the 4Site Workspace GCP
     project, enable the Calendar API, put `client_id` + desktop `client_secret` +
     `internal_domains` in `config.json`; sign in once (refresh token → **Keychain**).
  2. **Fathom**: generate an API key (**User Settings → API Access**), paste it (→ **Keychain**).
     ⚠️ Confirm the plan tier includes API access ([open-items.md](../open-items.md),
     [PLAN §14 item 1](../../PLAN.md)).
  3. Notifications permission (Phase 0) — the away prompt is delivered as a notification/prompt.

## Work items (mapped to modules / files)

### TidyIngest — Google Calendar

Under `Packages/TidyKit/Sources/TidyIngest/GoogleCalendar/` (`make generate` after adding files):

| File | Contents |
|---|---|
| `GoogleOAuth.swift` | loopback+PKCE authorize, code→token exchange, refresh, `invalid_grant`→re-auth; refresh token via `SecretStore` (Keychain, key e.g. `google.calendar.refresh_token`); access token **in memory only** |
| `CalendarClient.swift` | protocol: `listEvents(cursor:) -> (events, nextSyncToken)` |
| `LiveCalendarClient.swift` | `events.list`: initial `timeMin`/`timeMax`+`singleEvents=true`, incremental `syncToken`-only, `nextPageToken` paging, `410`→reset |
| `CalendarSource.swift` | `IngestSource` (`sourceKey = "google_calendar"`); §7.1 upserts; ensures access token before each run |
| `Mapping/CalendarMappers.swift` | event JSON → `calendar_events` record; RFC3339→epoch; `is_external` from `config.google.internal_domains`; `conference_url` resolution order (Meet `entryPoints` → `hangoutLink` → Zoom in `location` → Zoom in `description`) |

Gotchas to encode (from [google-calendar-api.md §8](../reference/google-calendar-api.md#8-client-shape--gotchas)):
`syncToken` + any of `timeMin`/`timeMax`/`orderBy`/`q` = **400** (keep two code paths);
`nextSyncToken` appears **only on the last page** (never store a mid-pagination token);
`singleEvents` must not flip; all-day (`start.date`) vs timed (`start.dateTime`) branch;
cancelled instances update `status`, never hard-delete; access token is never persisted.

### TidyIngest — Fathom

Under `Packages/TidyKit/Sources/TidyIngest/Fathom/`:

| File | Contents |
|---|---|
| `FathomClient.swift` | protocol: `listMeetings(createdAfter:) -> FathomMeetingsPage` |
| `LiveFathomClient.swift` | `GET /meetings` with `X-Api-Key` (Keychain), `include_transcript`/`include_summary=true`, `cursor` paging |
| `FathomSource.swift` | `IngestSource` (`sourceKey = "fathom"`); `created_after` cursor = max `created_at` seen; §7.1 meeting upsert + §7.2 replace-children invitees/utterances |
| `Mapping/FathomMappers.swift` | meeting JSON → records; `duration_seconds = recording_end − recording_start` (fallback scheduled span); `"HH:MM:SS"` → `start_seconds` offset; `email_domain`/`is_external` verbatim |

Rate discipline ([fathom-api.md rate limits](../reference/fathom-api.md#rate-limits),
[ingest-layer.md §6](../architecture/ingest-layer.md#6-rate-limits--exponential-backoff)): every
`/meetings` call with transcript+summary is a **heavy** call (30/min, as low as 5/min under load).
Run Fathom sync serially (concurrency 1); cap pages per run; fetch a transcript **once** (guard on
`meetings.has_transcript`), so heavy calls scale with *new* meetings, not polls.

### TidyStore

| File | Contents |
|---|---|
| `Migrations/V1Meetings.swift` | registers `v1-meetings` (calendar_events, meetings, meeting_invitees, transcript_utterances + indices) |
| `Records/CalendarEvent.swift`, `Meeting.swift`, `MeetingInvitee.swift`, `TranscriptUtterance.swift` | GRDB records, 1:1 with tables |
| `DAO/MeetingsDAO.swift` | upsert meeting; replace invitees/utterances per meeting; `meetingsForDay(_:)`; reconciliation lookups (by `ical_uid` / time+attendees) |

### TidyUnderstand (partial — meeting sessions only; full layer is Phase 5)

| File | Contents |
|---|---|
| `MeetingSessionBuilder.swift` | one `sessions` row per `meetings` row: `kind = 'meeting'`, `duration_seconds` = recording span, `source_ref = meetings.id`, attribution columns left NULL (classification is Phase 5) |

> Only the meeting-session *materialization* lands here. Sessionization of screen samples, the
> rules/lexical rungs, the sensitivity gate, and the learning loop are Phase 5
> ([understand-layer.md](../architecture/understand-layer.md)).

### TidySurface — away prompt

| File | Contents |
|---|---|
| `AwayPrompt/AwayPromptView.swift` | "Away 47 min: break, call, or something else?" — break (discard), call + who/which client (`pd_companies`/`pd_projects` picker), other (free text) |
| `AwayPrompt/AwayPromptCoordinator.swift` | observe new unresolved `away_gaps` on return-from-idle; present once; on answer write `attribution`/`note`/`client_id`/`project_id`/`resolved_at`; unanswered → leave `resolved_at` NULL to queue into the Phase 5 recap |

### TidyTimeApp

- Setup steps: run the Google consent flow (open system browser, catch loopback redirect); paste
  Fathom key; register `FathomSource` + `CalendarSource` with the `IngestCoordinator`.
- `doctor`: show Fathom & Google `sync_state` (`last_success_at`, `last_error`), Google auth health
  (surface a dead refresh token as "re-auth needed", not a silent stall), and meeting/event counts.

## Data model + migration

Phase 3 creates the **Meetings & calendar** tables exactly as in
[data-model.md → Meetings & calendar](../architecture/data-model.md#meetings--calendar-phase-3):
`meetings`, `meeting_invitees`, `transcript_utterances`, `calendar_events`. Mirror ids are provider
strings (`meetings.id` = Fathom recording id or `'cal:<eventid>'`; `calendar_events.id` = Google
event id) so re-sync is an upsert. Timestamps are **INTEGER epoch seconds UTC**; utterance offsets
are `REAL` seconds from `recording_start`.

Create `calendar_events` **before** `meetings` (the `meetings.calendar_event_id → calendar_events`
FK), then the child tables:

```swift
migrator.registerMigration("v1-meetings") { db in
    try db.create(table: "calendar_events") { t in
        t.column("id", .text).primaryKey()              // Google event id
        t.column("calendar_id", .text).notNull()
        t.column("title", .text)
        t.column("description", .text)
        t.column("location", .text)
        t.column("start_at", .integer).notNull()
        t.column("end_at", .integer).notNull()
        t.column("all_day", .integer).notNull().defaults(to: 0)
        t.column("status", .text)                       // confirmed | tentative | cancelled
        t.column("organizer_email", .text)
        t.column("attendees_json", .text)               // [{email,name,responseStatus,is_external}]
        t.column("conference_url", .text)
        t.column("ical_uid", .text)                     // join key to Fathom
        t.column("updated_at", .integer)
        t.column("fetched_at", .integer).notNull()
    }
    try db.create(table: "meetings") { t in
        t.column("id", .text).primaryKey()              // Fathom recording id or 'cal:<eventid>'
        t.column("source", .text).notNull()             // 'fathom' | 'calendar'
        t.column("title", .text)
        t.column("scheduled_start", .integer)
        t.column("scheduled_end", .integer)
        t.column("recording_start", .integer)           // ground truth for duration
        t.column("recording_end", .integer)
        t.column("duration_seconds", .integer).notNull()
        t.column("has_transcript", .integer).notNull().defaults(to: 0)
        t.column("has_summary", .integer).notNull().defaults(to: 0)
        t.column("summary", .text)
        t.column("external_url", .text)                 // Fathom share URL
        t.column("calendar_event_id", .text).references("calendar_events")
        t.column("fetched_at", .integer).notNull()
        t.column("created_at", .integer).notNull()
    }
    try db.create(table: "meeting_invitees") { t in
        t.column("id", .integer).primaryKey()
        t.column("meeting_id", .text).notNull()
            .references("meetings", onDelete: .cascade)
        t.column("email", .text)
        t.column("name", .text)
        t.column("email_domain", .text)                 // strong client signal
        t.column("is_external", .integer).notNull().defaults(to: 0)
    }
    try db.create(table: "transcript_utterances") { t in
        t.column("id", .integer).primaryKey()
        t.column("meeting_id", .text).notNull()
            .references("meetings", onDelete: .cascade)
        t.column("idx", .integer).notNull()             // order within transcript
        t.column("speaker", .text)
        t.column("speaker_email", .text)
        t.column("start_seconds", .double).notNull()    // offset from recording_start
        t.column("end_seconds", .double)
        t.column("text", .text).notNull()
    }
    try db.create(index: "idx_events_start",     on: "calendar_events",       columns: ["start_at"])
    try db.create(index: "idx_invitees_meeting", on: "meeting_invitees",      columns: ["meeting_id"])
    try db.create(index: "idx_invitees_domain",  on: "meeting_invitees",      columns: ["email_domain"])
    try db.create(index: "idx_utterances_meeting", on: "transcript_utterances", columns: ["meeting_id", "idx"])
}
```

### Upsert & duration rules

- **`meetings` / `calendar_events`**: string-PK upsert on `id`
  ([ingest-layer.md §7.1](../architecture/ingest-layer.md#71-string-pk-upsert-provider-id-is-the-primary-key)).
  `duration_seconds` computed on write = `recording_end − recording_start` when present, else
  `scheduled_end − scheduled_start` (ground-truth rule). Cancelled events upsert with
  `status = 'cancelled'` (row kept).
- **`meeting_invitees` / `transcript_utterances`**: replace-children — delete the parent's rows,
  reinsert the current set inside the sync transaction
  ([§7.2](../architecture/ingest-layer.md#72-replace-children-child-rows-keyed-only-by-a-local-rowid)).
  Only fetch/replace a transcript when `has_transcript = 0` (heavy-call budget).

### Cursors

`sync_state` rows (created here if absent):

| `source` | `cursor` | Advance rule |
|---|---|---|
| `google_calendar` | opaque `nextSyncToken` (verbatim) | store final-page token; `410`→null + full-resync window |
| `fathom` | `created_after` = max `created_at` seen (ISO-8601) | advance to newest meeting's `created_at` on success |

⚠️ Build-time check: confirm Fathom `created_after` is exclusive vs. inclusive (upserts make either
harmless, but store the cursor accordingly)
([fathom-api.md polling](../reference/fathom-api.md#polling--incremental-sync)).

### Entity-signal bootstrap inputs

The assignment's "entity-signal bootstrap from Productive + attendee domains" resolves to
**making the inputs available and normalized** in Phase 3:

- `meeting_invitees.email_domain` + `is_external` (Fathom, pre-parsed) and
  `calendar_events.attendees_json[].is_external` (Google, derived from
  `config.google.internal_domains`) are the attendee-domain signals.
- `pd_companies.domain` (Phase 2) is the Productive-domain signal.

The **`entity_signals` table is created in Phase 5** ([data-model.md phase map](../architecture/data-model.md#which-phase-creates-what);
`TidyUnderstand` builds in Phase 5). Minting `signal_type = 'email_domain'` rows
(provenance `bootstrapped`/`inferred`) reads these inputs then. See
[google-calendar-api.md §7](../reference/google-calendar-api.md#7-how-calendar-events-earn-their-keep)
and [understand-layer.md §2.2](../architecture/understand-layer.md#22-bootstrap-from-productive-vocabulary-setup--phase-5).
This ordering is called out in [uncertainties](#definition-of-done) — if the team wants signals
materialized in Phase 3, pull the `entity_signals` migration forward as an explicit seam.

## Key references

- **[reference/fathom-api.md](../reference/fathom-api.md)** — endpoint, auth, rate limits, the
  sample meeting JSON, the exact field→column mapping (incl. the `HH:MM:SS`→seconds helper), the
  recording-is-ground-truth rule, and polling/cursor semantics.
- **[reference/google-calendar-api.md](../reference/google-calendar-api.md)** — why the OAuth client
  must be **Internal** (the 7-day refresh-token trap), the loopback+PKCE flow (all four steps),
  `events.list` params, `syncToken`/`410` incremental sync, the `calendar_events` mapping,
  `is_external` derivation, and `conference_url` resolution order.
- [architecture/ingest-layer.md](../architecture/ingest-layer.md) — the `IngestSource` contract,
  cursor semantics (§4), rate-limit/backoff (§6), and upsert patterns (§7).
- [architecture/understand-layer.md §1.3](../architecture/understand-layer.md#13-meeting--slack-sessions-from-ingest-not-screen-samples)
  — how meeting sessions are built from ingest, not screen samples.
- [architecture/data-model.md → Meetings & calendar](../architecture/data-model.md#meetings--calendar-phase-3)
  — canonical DDL / column names; `away_gaps` (Phase 1) is the away-prompt target.
- [guardrails.md](../guardrails.md) — G6 (refresh token/API key in Keychain), G8 (one process,
  poll-driven), G9 (`transcript_utterances` purge after retention; keep the `meetings` summary row).
- [PLAN.md §5 (Fathom, Google Calendar)](../../PLAN.md) and [§11 Phase 3](../../PLAN.md).

## Risks

- **⚠️ Google OAuth must be Internal type.** External/Testing clients expire the refresh token in
  **7 days** for the sensitive `calendar.readonly` scope — ingest would silently stop weekly. An
  Internal app (4Site Workspace) has no Testing gate and no 7-day expiry
  ([google-calendar-api.md §2](../reference/google-calendar-api.md#2-why-the-oauth-client-must-be-created-as-internal-user-type)).
  `doctor` must surface a dead Google auth as "re-auth needed."
- **`syncToken` misuse = 400 / lost events.** Never send time/order params with a `syncToken`;
  never store a token mid-pagination (it appears only on the last page). Keep two distinct paths.
- **⚠️ Fathom plan tier / API access unproven.** If the tier lacks API access, degrade to
  **calendar-only meetings** (no transcripts, scheduled-slot duration) rather than failing
  ([fathom-api.md open item](../reference/fathom-api.md#open-item), [open-items.md](../open-items.md)).
- **Fathom heavy-call throttle** (30/min, floor 5/min under load): serialize sync, cap pages per
  run, never re-pull a stored transcript. A 10-min poll leaves ample headroom.
- **Duration must come from the recording, not the calendar** (PLAN §5, §8). A 60-min booked slot
  can be a 60m53s recording; store the recording span and keep utterance offsets so the Phase 5–6
  split reconciles to a timestamp range
  ([fathom-api.md duration](../reference/fathom-api.md#duration-is-the-recording-not-the-calendar)).
- **Reconciliation false-merges.** Matching Fathom↔Calendar on time alone can merge back-to-back
  meetings; require `ical_uid` match *or* attendee-set overlap within the time window before
  linking `calendar_event_id`. Leave `NULL` when unsure.
- **⚠️ Desktop `client_secret` handling.** For an installed app the secret is not confidential but
  Google's token endpoint may still require sending it — confirm at build time
  ([google-calendar-api.md §2](../reference/google-calendar-api.md#2-why-the-oauth-client-must-be-created-as-internal-user-type)).
- **Sensitivity (G2) / retention (G9).** Transcripts are the highest-sensitivity content TidyTime
  touches. Phase 3 only *stores* them locally; no transcript/summary/invitee data reaches a cloud
  rung until the Phase 6 sensitivity gate passes it. `transcript_utterances` purge after the
  retention window (keep the `meetings` summary row) — the Phase 1 retention job already covers
  the table name.
- **All-day vs timed / TZ.** Branch on `start.date` vs `start.dateTime`; always parse the RFC3339
  offset; never assume the machine zone equals the event zone.

## Acceptance criteria (faithful to PLAN §11 Phase 3)

> *"Accept when: yesterday's meetings appear with real recorded durations and attendees, and coming
> back from a long gap asks you about it."* — [PLAN.md §11](../../PLAN.md)

- [ ] **Yesterday's meetings appear with real recorded durations.** For each Fathom-recorded meeting
      yesterday, a `meetings` row exists with `duration_seconds` = `recording_end − recording_start`
      (not the scheduled slot), and a corresponding `sessions` row (`kind = 'meeting'`) carries that
      duration.
- [ ] **…and attendees.** `meeting_invitees` lists each meeting's attendees with `email_domain` and
      `is_external`; a mixed-tenancy call shows at least one `is_external = 1` contact.
- [ ] **Transcripts present.** Recorded meetings have `has_transcript = 1` and ordered
      `transcript_utterances` (speaker + `start_seconds` offset from `recording_start`).
- [ ] **Calendar coverage.** `calendar_events` mirrors yesterday/today's events with correct
      `start_at`/`end_at`, `status`, `conference_url` (Meet or Zoom), and derived `is_external`
      attendees; a confirmed timed event Fathom didn't record becomes a `'cal:<eventid>'` meeting.
- [ ] **Returning from a long gap prompts you.** After an idle/lock/sleep interval past the threshold
      (default 10 min → an `away_gaps` row), the away prompt fires on return; answering it writes
      `attribution` (+ `note`/`client_id` for a call) and `resolved_at`; an ignored prompt leaves
      `resolved_at` NULL to queue into the recap.
- [ ] **Incremental & idempotent.** A second `sync()` with no upstream changes writes zero new rows
      and does not move either cursor; a Calendar `410` triggers a clean full-resync
      ([ingest-layer.md §10](../architecture/ingest-layer.md#10-acceptance-criteria)).
- [ ] **Auth durability.** The Google refresh token survives across days (Internal-type client); a
      revoked/`invalid_grant` token surfaces in `doctor` as re-auth, not a silent stall.

## Definition of done

- [ ] `make build` compiles; `make test` passes — fixture-based tests for both sources, the OAuth
      token unit (refresh, `invalid_grant`), Fathom mapping (four time fields → epoch, `HH:MM:SS`
      → `start_seconds`, duration = recording span with scheduled fallback, pagination terminates on
      null cursor), Calendar mapping (all-day vs timed, `conference_url` order, cancelled), Fathom↔
      Calendar reconciliation, and the away-prompt write-back. **No live network.**
- [ ] `v1-meetings` is a **new** registered migration; [data-model.md](../architecture/data-model.md)
      already reflects these tables (confirm no drift).
- [ ] **G6**: Fathom API key and Google **refresh** token are in Keychain only; the Google **access**
      token lives in memory only; `config.json` holds only non-secret Google client/`internal_domains`.
      No secret in DB, logs, or committed fixtures (fixtures scrubbed of `X-Api-Key` / tokens and of
      real personnel content).
- [ ] **G8**: both sources run as `async` tasks under the existing `IngestCoordinator` — no daemon,
      no helper, no webhook receiver.
- [ ] **G9**: `transcript_utterances` are registered with the retention job (purge after window; keep
      `meetings` summary rows).
- [ ] Meeting `sessions` are materialized with Fathom-true durations; classification columns remain
      NULL (Phase 5 owns classification).
- [ ] Attendee/invitee domains + `is_external` are parsed and stored; the entity-signal *inputs* are
      available for Phase 5 bootstrap (see [uncertainties note](#entity-signal-bootstrap-inputs)).
- [ ] `doctor` surfaces Fathom/Google `sync_state`, Google auth health, and meeting/event counts.
- [ ] No new lint violation of the prime directives; the read-only posture holds (both clients GET-only).

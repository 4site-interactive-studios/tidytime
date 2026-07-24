# TidyIngest

Read-only API clients and incremental sync engines for Productive, Fathom, Google Calendar, and
Slack, mirroring each source into the local store.

Related: [docs index](../../../../docs/README.md) ·
[ingest-layer](../../../../docs/architecture/ingest-layer.md) ·
[data-model](../../../../docs/architecture/data-model.md) ·
[guardrails](../../../../docs/guardrails.md) ·
[TidyStore](../TidyStore/README.md)

## Responsibility

One protocol-backed client per source, each fetching and upserting into its mirror tables, with
cursors in `sync_state` and rate-limit/backoff handling. Productive access is **GET-only** (G1).

## Phase

Builds across **Phases 2–4**: Productive (P2), Fathom + Google Calendar (P3), Slack (P4).

## Dependencies

- Internal: **TidyCore**, **TidyStore**. Does **not** depend on TidyCapture or TidyAI.

## Key types & files

| Type / file | Purpose |
|---|---|
| `LiveProductiveClient` | `ProductiveClient` (read) impl; JSON:API `GET` only — no mutating method exists (G1). |
| `FathomClient` | Meetings, invitees, transcripts (recording span = ground-truth duration). |
| `GoogleCalendarClient` | Read-only OAuth; events + attendees; `syncToken` incremental sync. |
| `SlackClient` | Conversation history for tracked channels / DMs. |
| `IngestSource` engines | Per-source `sync()` + cursor management via `sync_state`. |

## Tables

- **Writes:** `pd_companies`, `pd_projects`, `pd_tasks`, `pd_time_entries`, `pd_people` (P2);
  `meetings`, `meeting_invitees`, `transcript_utterances`, `calendar_events` (P3);
  `slack_messages` (P4).
- **Reads/writes:** `sync_state` (one row per source: `cursor`, `last_run_at`, `last_error`).

## Protocol seams

**Owns** `ProductiveClient` (read) and `IngestSource`. Consumes `SecretStore` (all tokens from the
Keychain — G6) and `Clock`. Guardrails: **G1** (Productive GET-only), **G6** (secrets in Keychain
only).

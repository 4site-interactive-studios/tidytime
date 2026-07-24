# 0006 — GRDB + SQLite (WAL) single-file store

All local state lives in one SQLite database accessed through GRDB in WAL mode; tokens live in the
Keychain, non-secret config in a readable JSON file.

Related: [README.md](README.md) · [../architecture/data-model.md](../architecture/data-model.md) ·
[../guardrails.md](../guardrails.md) · [0012](0012-retention-90-days-summaries-forever.md)

**Status:** Accepted · **Date:** 2026-07-23

## Context

TidyTime writes high-frequency capture rows (every app/window switch plus a 30-second heartbeat),
mirrors the Productive slice, and stores meetings, transcripts, Slack, signals, suggestions, and
the AI ledger. It needs a fast, embedded, transactional store with real migrations, from a
single-process Swift app under a ~2% CPU bar (PLAN §3–§4). A server database is overkill and adds
an ops surface a personal app shouldn't have.

## Decision

Use **SQLite via [GRDB](https://github.com/groue/GRDB.swift)** — the standard Swift SQLite
toolkit — at `~/Library/Application Support/TidyTime/tidytime.sqlite`, in **WAL mode** (PLAN §6).
`TidyStore` owns setup, the `DatabaseMigrator`, DAOs, and the retention job. Open PRAGMAs:
`foreign_keys = ON`, `journal_mode = WAL`, `busy_timeout = 5000`. GRDB record types map **1:1** to
the tables in [data-model.md](../architecture/data-model.md). Schema changes are **new migrations,
never edits to a shipped one.** Secrets go to the **Keychain only** (guardrail
[G6](../guardrails.md#g6--secrets-live-in-the-keychain-only)); `config.json` holds non-secret
settings and is a readable file so future teammate setup is transparent.

## Consequences

- WAL lets the capture writer and UI readers coexist without blocking; batched writes keep CPU low.
- One file is the entire privacy blast radius — encrypted at rest by FileVault, purged on schedule
  (guardrail [G9](../guardrails.md#g9--retention-and-privacy-blast-radius),
  [0012](0012-retention-90-days-summaries-forever.md)).
- `DatabaseMigrator` gives ordered, immutable migrations; `eraseDatabaseOnSchemaChange = true` is
  allowed in `DEBUG` only, never release (see [data-model.md](../architecture/data-model.md)).
- Timestamps store as INTEGER Unix epoch **seconds UTC**; our durations in **seconds**; Productive
  mirror tables keep the API's **minutes** — the convention every doc shares.
- WAL leaves `-wal`/`-shm` sidecar files; the DB path handling and any backup logic must account
  for them.

## Alternatives considered

- **Core Data / SwiftData.** Rejected: heavier object graph, migration story less transparent for a
  schema this SQL-shaped, and harder to reason about at the row level the retention job needs.
- **Raw SQLite C API.** Rejected: GRDB gives Codable records, a migrator, and a safe concurrency
  model with far less boilerplate.
- **A server/embedded key-value store.** Rejected: an ops surface and a query model that don't fit
  a single-process, single-file personal app.

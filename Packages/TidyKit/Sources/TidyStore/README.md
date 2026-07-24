# TidyStore

GRDB database setup, the migrator, DAOs / read-model query helpers, and the retention job. The
single funnel for all database I/O and the owner of the schema.

Related: [docs index](../../../../docs/README.md) ·
[data-model](../../../../docs/architecture/data-model.md) ·
[module-map](../../../../docs/architecture/module-map.md) ·
[guardrails](../../../../docs/guardrails.md) ·
[TidyCore](../TidyCore/README.md)

## Responsibility

Opens the SQLite database (WAL + PRAGMAs), runs the `DatabaseMigrator`, exposes DAOs and read
models, and runs the retention purge. Every other target writes through its DAOs.

## Phase

Builds in **Phase 0** (DB open + baseline migrator, config path). The **retention job** lands in
**Phase 1** (G9). Each later phase adds its own migration for that phase's tables.

## Dependencies

- Internal: **TidyCore** (record types, `Config`, `Clock`, logging).
- External: `GRDB`.

## Key types & files

| Type / file | Purpose |
|---|---|
| `AppDatabase` / `DatabaseManager` | Opens `~/Library/Application Support/TidyTime/tidytime.sqlite`; sets `foreign_keys=ON`, `journal_mode=WAL`, `busy_timeout=5000`. |
| `Migrations` | Registered `DatabaseMigrator` migrations (`v1-baseline`, or per-phase `v1-capture`, `v1-productive`, …), applied in order, **never edited once shipped**. |
| DAOs / query helpers | One per table group; the read models TidySuggest and TidySurface consume. |
| `RetentionJob` | Scheduled purge of aged raw rows (G9). |

## Tables

**Owns the schema for all tables** in
[data-model](../../../../docs/architecture/data-model.md). Retention purges `activity_samples`,
`page_snapshots`, `slack_messages`, `transcript_utterances` (default 90 days, per-table
configurable); distilled tables — `sessions`, `suggestions`, `decisions`, `daily_rollups`,
`entity_signals`, `pools`, `ai_calls` — persist.

## Protocol seams

Consumes `Clock` (retention windows) from TidyCore. Provides the DAO / read-model seams that every
writing target and TidySurface depend on. Guardrail: **G9** (retention & blast radius).

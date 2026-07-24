# TidyKitTests

The single test bundle for every TidyKit target: unit suites organized by module, backed by
recorded fixtures, an in-memory GRDB database, and the guardrail tests.

Related: [docs index](../../../../docs/README.md) ·
[testing-strategy](../../../../docs/build/testing-strategy.md) (authoritative) ·
[guardrails](../../../../docs/guardrails.md) ·
[data-model](../../../../docs/architecture/data-model.md) ·
[module-map](../../../../docs/architecture/module-map.md)

## What this is

`TidyKitTests` is one SwiftPM test target that depends on all eight libraries (see `Package.swift`).
There is no live network and no live Accessibility here — I/O sits behind the TidyCore protocol
seams, so tests inject fixtures and a deterministic `Clock`. The authoritative spec is
[testing-strategy](../../../../docs/build/testing-strategy.md); this file is the local map.

## Suite organization (by module)

Group files by the module under test — `TidyCoreTests`, `TidyStoreTests`, `TidyCaptureTests`,
`TidyIngestTests`, `TidyUnderstandTests`, `TidyAITests`, `TidySuggestTests`, `TidySurfaceTests` —
plus a `GuardrailTests` suite. Each phase's PR adds its own suites (and any new guardrail tests for
the risk it introduces).

## Fixtures & harness

| Piece | How |
|---|---|
| In-memory DB | `DatabaseQueue()` (no file) migrated by `TidyStore.Migrations`; assert against DAOs. |
| Recorded fixtures | Per ingest source — captured JSON responses under `Fixtures/`; **no secrets committed** (G6). |
| Deterministic time | Inject a fixed `Clock`; never read wall-clock in assertions. |
| Fake providers | `AIProvider` stubs; the sensitivity gate seeded with known phrases. |

## Guardrail tests (from testing-strategy + guardrails)

| ID | Assertion |
|---|---|
| G1 | Productive request builder rejects any non-`GET`; no mutating path exists. |
| G2 | A seeded sensitive phrase appears in **no** outbound-payload log. |
| G3 | Grep `TidyCapture` sources for `CGWindowList` name usage → none. |
| G4 | A rung-1/2-confident session never reaches a cloud rung; `produced_by_rung` is correct. |
| G5 | Every cloud call writes an `ai_calls` row; over-cap requests refused before dispatch. |
| G6 | Logger + outbound-payload log emit no secret material; config has no secret fields. |
| G9 | Seed aged `activity_samples` / `page_snapshots` / etc.; retention purges them, distilled rows stay. |

> ⚠️ Build-time check: **G7** (stable signature) and **G8** (no `launchd` / XPC helper) are
> verified in the build & signing config, not by unit tests — see
> [signing-and-tcc](../../../../docs/build/signing-and-tcc.md).

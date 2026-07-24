# Phase 1 retrospective — Capture

**Date:** 2026-07-23 · **Status:** ✅ logic complete, tests green (46 total, +24) · **Commit:** `feat(phase-1)`

## What shipped (code-complete + unit-tested)

| Area | Type(s) | Tested by |
|---|---|---|
| Schema | `v1-capture` migration → activity_samples, page_snapshots, sessions, away_gaps, sync_state | `CaptureMigrationTests` |
| Records + DAOs | `ActivitySample`, `PageSnapshot`, `Session`, `AwayGap`, `SyncState` + insert/fetch/close/sync helpers | `SampleRecorderTests`, `SyncStateTests` |
| Context keys | `ContextKey.derive` (web:host / app:bundle) | `ContextKeyTests` (3) |
| Page text | `PageTextPolicy` (byte truncation, sha256, dedup) | `PageTextPolicyTests` (3) |
| Sessionization | `Sessionizer` (detour absorption, min-session drop, primaryApp) | `SessionizerTests` (5) |
| Away gaps | `AwayGapDetector` (idle threshold, explicit lock/sleep) | `AwayGapDetectorTests` (3) |
| Recording | `SampleRecorder` (closes prior sample, page-text dedup) | `SampleRecorderTests` (2) |
| Session build | `SessionBuildJob` (slice building, open-sample→now, persist) | `SessionBuildJobTests` (2) |
| Retention | `RetentionJob` (purge > window, cascade, skip absent) | `RetentionTests` (2) |

Coverage: **73.9% line** on `Sources/`. The gap is dominated by `LiveCapture.swift`
(compile-only OS adapters, ~130 lines that can't run headlessly).

## Divergences / decisions (see DECISIONS.md for detail)

- **Min-session runs are dropped, not merged** — sub-threshold time is recovered as micro-work
  pools in Phase 5, so nothing is truly lost.
- **`IdleReader` avoids the `CGEventType(rawValue: ~0)!` idiom** that would trap at runtime; uses
  the min across concrete event types instead.
- **Cross-phase FK columns** (`sessions.client_id`, …) created without `REFERENCES` in `v1-capture`.
- **Retention is strictly-older-than** the window (boundary rows kept).

## Deferred to manual verification (needs a running app + TCC grants)

- App/window watcher actually firing on activation; AX window-title reads; Chrome AppleScript for
  URL/title and `execute javascript` page text (incl. the "Allow JavaScript from Apple Events"
  walkthrough); real idle seconds; sleep/lock away gaps. All compile; none run in `swift test`.
- **Acceptance criterion "a full workday reads back as a coherent session timeline"**: verifiable
  only on a real Mac. The transformation from samples → timeline (`SessionBuildJob`) IS tested with
  synthetic samples; what's unproven here is that the live watchers produce faithful samples.

## Notes for Phase 2 (Productive mirror)

- Add the `v1-productive` migration (pd_companies/projects/tasks/time_entries/people).
- Build the Productive JSON:API client behind a `ProductiveClient` protocol with a fake backed by
  recorded fixture JSON (put fixtures under `Tests/.../Fixtures/`). **Guardrail G1:** the client
  exposes only GET; add a guardrail test asserting no mutating request can be constructed.
- Reuse `sync_state` for the incremental cursor. `SessionBuildJob` output (`context_key`) will feed
  entity resolution later; no attribution work in Phase 2.

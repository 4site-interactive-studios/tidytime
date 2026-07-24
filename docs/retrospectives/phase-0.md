# Phase 0 retrospective — Test & debug infrastructure

**Date:** 2026-07-23 · **Status:** ✅ complete, tests green (24 passing) · **Commit:** `feat(phase-0)`

## Goal recap

Before any feature work: stand up (1) automated tests wired into the workflow, (2) structured
file logging AI tools can read, and (3) a manual debug mode that copies a diagnostic bundle to the
clipboard. Plus the Phase-0 skeleton (DB, config, Keychain).

## What shipped (code-complete + unit-tested)

| Area | Type(s) | Tested by |
|---|---|---|
| Config load (nested, defaulted, round-trips `config.example.json`) | `Config`, `ConfigLoader` | `ConfigTests` (5) |
| Secret storage | `SecretStore` proto, `KeychainSecretStore`, `InMemorySecretStore` | `SecretStoreTests` |
| Secret redaction | `Redactor` (explicit + pattern) | `RedactionTests` (4) |
| Structured logging | `TidyLogger`, `FileLogSink` (rotating JSONL), `InMemoryLogSink`, `LogReader` | `TidyLogTests` (3) |
| Injectable time | `TidyClock`, `SystemClock`, `FixedClock` | used throughout |
| Database | `AppDatabase` (GRDB, WAL, FK), `Migrations` (`v1-core`), `AppMetadata` DAO, `installId` | `StoreTests` (4) |
| Diagnostics bundle | `DiagnosticsInput`, `DiagnosticsBundle.render`, `DiagnosticsAssembler`, `ClipboardWriter`/`FakeClipboard` | `DiagnosticsTests` (3), `DebugModeTests` (2) |
| Host info | `HostInfo` (os/app/device) | `HostInfoTests` |

**Test infra:** `make test` (`swift test`) and `make coverage` (`scripts/coverage.sh` → llvm-cov).
Line coverage on `Sources/` ≈ **75%** (regions 68%, functions 61%). The uncovered remainder is
mostly platform code that can't run headlessly (real Keychain, log-file rotation edge, on-disk
error paths) — see below.

**Guardrail test landed:** `DebugModeTests.testCopyDiagnosticsProducesRedactedUsefulBundle` seeds a
real secret value into the store + logs and proves it never reaches the clipboard (G6).

## Divergences from the plan

- **`Clock` → `TidyClock`.** Renamed to avoid colliding with Swift's stdlib `Clock` protocol. The
  conventions doc referenced `Clock`; the concept is unchanged.
- **`v1-core` migration** (an `app_metadata` key/value table) added in Phase 0 so the store layer
  has something real to open/test and the diagnostic bundle can report row counts. Domain tables
  still land in their phases per the data-model phase map.
- **Diagnostic bundle location.** Assembly (`DiagnosticsAssembler`) lives in `TidyStore` (needs DB
  row counts); the pure renderer + `ClipboardWriter` seam live in `TidyCore`; `NSPasteboard` impl in
  `TidySurface`. This keeps everything except the actual clipboard write unit-testable.

## Deferred to manual verification (needs a real Mac / Xcode / running app)

These compile but are not exercised by `swift test`, and their Phase-0 acceptance is **manual**:

- The menu-bar app actually appearing and surviving reboot (`MenuBarExtra` + `SMAppService`
  launch-at-login) — requires `xcodegen` + `xcodebuild` + signing. `xcodegen` is **not installed**
  in this environment; `make bootstrap` will install it via Homebrew on a dev Mac.
- The in-app **doctor view** (live TCC/permission status). `make doctor` prints paths; the live
  permission panel is app-target UI. The data behind it (`DiagnosticsAssembler`) is done + tested.
- Real Keychain round-trip (`KeychainSecretStore`) — would prompt/behave environment-specifically;
  tests use `InMemorySecretStore`.

**Flagged blocker for the human:** to hit the literal Phase-0 acceptance ("icon in the menu bar,
survives reboot, doctor shows status"), run `make bootstrap && make run` on the target Mac after
setting `DEVELOPMENT_TEAM` in `Local.xcconfig`. Nothing in the automated suite can prove it.

## Notes for the next phase (Phase 1 — Capture)

- The capture pipeline should write through `TidyStore` DAOs; add the `v1-capture` migration
  (activity_samples, page_snapshots, sessions, away_gaps, sync_state) as its own registered
  migration.
- Put `NSWorkspace`/`AXUIElement`/Chrome-AppleScript behind protocols (`AppActivitySource`,
  `WindowTitleReading`, `BrowserAdapter`) in `TidyCore`/`TidyCapture` so sessionization + the
  adapter policy are testable with fakes; only the live OS wiring stays untested.
- Sessionization, idle/detour logic, and the retention job are pure/tested logic — build them
  against `FixedClock` and an in-memory DB.
- Watch the `.gitignore` lesson (DECISIONS.md): don't add broad ignore globs.

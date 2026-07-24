# Phase 0 — Skeleton

Stand up a signed, launch-at-login **`MenuBarExtra`** app with a real GRDB database, a loadable
`config.json`, Keychain-backed secret plumbing, and a `doctor` debug view — the scaffold every
later phase builds on.

**Related:** [../README.md](../README.md) (doc index) ·
[../../PLAN.md](../../PLAN.md) §11 (Phase 0) ·
[../architecture/module-map.md](../architecture/module-map.md) (targets & dependency rules) ·
[../architecture/data-model.md](../architecture/data-model.md) (schema / migrations) ·
[../build/signing-and-tcc.md](../build/signing-and-tcc.md) (stable signing) ·
[phase-1-capture.md](phase-1-capture.md) (next phase) ·
[../guardrails.md](../guardrails.md) (G6, G7, G8)

---

## Scope (in / out)

**In:**

- Repo tooling: `Makefile`, XcodeGen `project.yml`, `Packages/TidyKit/Package.swift` declaring all
  **eight** library targets ([module-map.md](../architecture/module-map.md)), `.gitignore`.
- App shell: `TidyTimeApp` (`App/`) as a menu-bar-only (`LSUIElement`) `MenuBarExtra` scene with a
  minimal popover.
- Store: `TidyStore` opens the SQLite file at the canonical path (WAL + PRAGMAs) and runs a
  `DatabaseMigrator` whose first migration, **`v1-capture`**, creates the Phase-1 capture tables.
- Core: `TidyCore` with `Config` loading, `SecretStore`/`KeychainSecretStore`, `TidyLog`, `Clock`,
  `AppPaths`, shared errors, and the GRDB record types for the capture tables.
- Launch-at-login via `SMAppService.mainApp` ([overview.md](../architecture/overview.md#launch-at-login-smappservice)).
- Stable code signing wired from a committed base + gitignored `Local.xcconfig`
  ([signing-and-tcc.md](../build/signing-and-tcc.md), guardrail G7).
- The `doctor` view (in-app) + `make doctor` (terminal): DB path, config path, permission status,
  launch-at-login status, signing identity.

**Out (later phases):**

- Any capture (no watcher, no Chrome, no idle/away) — that is **Phase 1**
  ([phase-1-capture.md](phase-1-capture.md)). Phase 0 only *creates* the capture tables; nothing
  writes rows yet.
- Any network / API client (Productive, Fathom, Google, Slack) — Phases 2–4.
- Any classification, suggestion, or AI code — Phases 5–6.
- Accessibility / Automation / Notification **prompts** — Phase 0 only *reports* their status in
  `doctor`; it requests nothing (those prompts land when the feature that needs them ships).

---

## Prerequisites

- macOS 14+ on the target machine; Xcode 16+ (Swift 6 toolchain). Deployment target macOS 14
  ([CLAUDE.md](../../CLAUDE.md) Tech stack).
- `brew` available (for `make bootstrap` → XcodeGen install).
- A free Apple ID **personal team** (or a stable self-signed cert) for signing — no paid Apple
  Developer account. Read [signing-and-tcc.md](../build/signing-and-tcc.md) first: an unstable
  signature silently strips TCC grants (guardrail G7).
- No secrets required yet — tokens are pasted in the phases that consume them.

---

## Work items

A checklist mapped to the files/modules to create. Regenerate the Xcode project
(`make generate`) after adding files so XcodeGen picks them up.

### Tooling & project generation

- [ ] `Packages/TidyKit/Package.swift` — SwiftPM package declaring the eight library targets
      (`TidyCore`, `TidyStore`, `TidyCapture`, `TidyIngest`, `TidyUnderstand`, `TidyAI`,
      `TidySuggest`, `TidySurface`) + matching test targets, with GRDB as a dependency. Empty
      stubs are fine for targets not touched this phase; the dependency arrows must match
      [module-map.md](../architecture/module-map.md) (only `TidyCore` depends on nothing internal).
- [ ] `project.yml` — XcodeGen spec for the `TidyTime` app target pointing at `App/`, linking the
      `TidyKit` package, and pulling signing from `Local.xcconfig`. Detail:
      [../build/xcodegen-spec.md](../build/xcodegen-spec.md).
- [ ] `Makefile` — `bootstrap`, `generate`, `build`, `run`, `test`, `doctor`
      ([CLAUDE.md](../../CLAUDE.md) Build/run/test).
- [ ] `.gitignore` — `config.json`, `*.sqlite*`, `Local.xcconfig`, `secrets*`, `TidyTime.xcodeproj`,
      `.build/`, `DerivedData/` (guardrails G6, G7).
- [ ] `config.example.json` — the config schema (copy → `config.json`, gitignored).

### TidyCore (`Packages/TidyKit/Sources/TidyCore/`)

- [ ] `Config/AppPaths.swift` — resolves `~/Library/Application Support/TidyTime/`, the DB path
      (`tidytime.sqlite`), and `config.json`; creates the directory if missing.
- [ ] `Config/Config.swift` — `Codable` model + loader for `config.json`. **Non-secret settings
      only** (guardrail G6); parsing has no field for tokens. Missing file → typed error with the
      expected path (not a crash).
- [ ] `Secrets/SecretStore.swift` — the `SecretStore` protocol (`get`/`set`/`delete`) and a
      `SecretKey` enum enumerating every token key (`productive`, `fathom`, `slackUser`,
      `googleRefresh`, `fireworks`, `anthropic`). This is the **only** secret accessor (module-map
      protocol seam).
- [ ] `Secrets/KeychainSecretStore.swift` — Keychain (`kSecClassGenericPassword`) impl, service =
      bundle id `com.4site.TidyTime`, account = key raw value. Never logs values (guardrail G6).
- [ ] `Logging/TidyLog.swift` — `os.Logger` wrapper (subsystem = bundle id, per-area categories).
      Redacts token-shaped strings; **never `print`** ([../conventions/error-handling-logging.md](../conventions/error-handling-logging.md)).
- [ ] `Time/Clock.swift` — `Clock` protocol + `SystemClock` (injectable for deterministic tests;
      module-map protocol seam).
- [ ] `Errors/TidyError.swift` — shared typed errors (`ConfigError`, `StoreError`, `SecretError`).
- [ ] `Records/*.swift` — GRDB record structs mapping **1:1** to the capture tables
      (`ActivitySample`, `PageSnapshot`, `Session`, `AwayGap`, `SyncState`); `Codable` +
      `FetchableRecord` + `MutablePersistableRecord`. Field names/types verbatim from
      [data-model.md](../architecture/data-model.md).

### TidyStore (`Packages/TidyKit/Sources/TidyStore/`)

- [ ] `Database/DatabaseManager.swift` — opens the DB via a GRDB `DatabasePool` (WAL) at
      `AppPaths.dbPath`, applies PRAGMAs (`foreign_keys=ON`, `journal_mode=WAL`,
      `busy_timeout=5000`), and runs the migrator. Exposes the pool to DAOs.
- [ ] `Database/Migrations.swift` — the `DatabaseMigrator`; registers **`v1-capture`** creating
      `activity_samples`, `page_snapshots`, `sessions`, `away_gaps`, `sync_state` exactly as in
      [data-model.md](../architecture/data-model.md). `eraseDatabaseOnSchemaChange = true` **in
      `DEBUG` only**.
- [ ] `Diagnostics/Diagnostics.swift` — the value the `doctor` view/CLI renders: DB path + exists +
      size, applied migrations, config path + load status, permission statuses, launch-at-login
      status, bundle id + signing identity.

### App shell (`App/`)

- [ ] `App/TidyTimeApp.swift` — `@main`, the `MenuBarExtra` scene, and the dependency container that
      constructs `Config`, `DatabaseManager`, and `KeychainSecretStore` at launch.
- [ ] `App/MenuBarContent.swift` — minimal popover: capture-status label (static "idle" this
      phase), **Open Doctor**, **Quit**.
- [ ] `App/DoctorView.swift` — SwiftUI view rendering `Diagnostics`; a **Refresh** button re-reads
      permission status live.
- [ ] `App/LaunchAtLogin.swift` — `SMAppService.mainApp` register/unregister + `.status` read
      (snippet in [overview.md](../architecture/overview.md#launch-at-login-smappservice)); surface
      `.requiresApproval` in `doctor`.
- [ ] `App/Info.plist` — `LSUIElement = true` (menu-bar-only, no Dock icon), `CFBundleIdentifier`
      `com.4site.TidyTime`, version keys. Automation/Apple-Events usage strings may be stubbed now
      and finalized in Phase 1.
- [ ] `App/TidyTime.entitlements` — App Sandbox is **off** in v1 (sandbox blocks the Accessibility
      API and cross-app Automation that Phase 1 needs); Hardened Runtime handled by the signing
      base ([signing-and-tcc.md](../build/signing-and-tcc.md)).

### Doctor (terminal)

- [ ] `make doctor` — build the app, then run its binary with a `--doctor` launch argument that
      prints `Diagnostics` to stdout and exits `0`. ⚠️ **Build-time check:** confirm the exact
      binary path emitted by `xcodebuild -showBuildSettings` and whether a headless run needs
      `NSApplication` bootstrapping; a tiny CLI entry that skips the scene is acceptable.

### Config schema (`config.example.json`)

The committed [`config.example.json`](../../config.example.json) is the canonical, **nested**
schema — Phase 0 loads it whole (every later phase's fields already ship in it; nothing is
"added later"). Use these exact key paths (later phases reference them: `config.organization.timezone`,
`config.capture.idle_threshold_seconds`, `config.sessionization.detour_tolerance_seconds`,
`config.suggestions.standalone_threshold_minutes`, `config.recap.time`, `config.nudges.quiet_hours`).
Faithful excerpt:

```json
{
  "organization": {
    "productive_organization_id": "REPLACE_WITH_ORG_ID",
    "productive_person_id": "resolved_at_setup",
    "timezone": "America/New_York"
  },
  "capture": {
    "browser": "chrome",
    "heartbeat_seconds": 30,
    "idle_threshold_seconds": 600,
    "page_text_max_bytes": 4096,
    "kill_switches": { "app_watcher": true, "chrome": true, "calendar": true, "fathom": true, "slack": true }
  },
  "sessionization": { "detour_tolerance_seconds": 120, "min_session_seconds": 60 },
  "suggestions": { "increment_minutes": 15, "round_up_bias": 0.4, "standalone_threshold_minutes": 15 },
  "recap": { "time": "17:00", "morning_catchup": true },
  "nudges": { "enabled": true, "daily_cap": 5, "quiet_hours": { "start": "18:00", "end": "09:00" } },
  "sensitivity": { "keywords": [], "flagged_people": [], "flagged_terms": [] },
  "retention_days": { "activity_samples": 90, "page_snapshots": 90, "slack_messages": 90, "transcript_utterances": 90 }
}
```

Phase 0 only *reads* the settings it needs (DB path, timezone, retention); later phases consume
their own keys. The `productive.task_deep_link_pattern` is confirmed in Phase 2. Tokens are
**never** here — they live in the Keychain (guardrail G6).

---

## Data model

- **Tables touched:** none written yet; the migration **creates** `activity_samples`,
  `page_snapshots`, `sessions`, `away_gaps`, `sync_state`
  ([data-model.md](../architecture/data-model.md) — Capture tables).
- **GRDB migration name:** **`v1-capture`** — the first (baseline) migration, registered here so
  Phase 0 has a real schema for `doctor` to point at and a testable insert/read round-trip. Phase 1
  populates these tables and adds **no** new migration.
- **Migration rule:** never edit a shipped migration; corrections are a new migration
  ([data-model.md](../architecture/data-model.md#migrations)). `eraseDatabaseOnSchemaChange` is
  `DEBUG`-only.

> **Boundary note:** [data-model.md](../architecture/data-model.md) lists these five tables under
> Phase 1 (the phase whose feature set *exercises* them). Phase 0 lands the `v1-capture` migration
> that *creates* them; both docs name the same migration, so there is one source of truth for the
> DDL. See `uncertainties` in the build handoff.

```swift
// Packages/TidyKit/Sources/TidyStore/Database/Migrations.swift
func registerMigrations(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v1-capture") { db in
        try db.execute(sql: """
            CREATE TABLE activity_samples ( ... );   -- verbatim from data-model.md
            CREATE TABLE page_snapshots   ( ... );
            CREATE TABLE sessions         ( ... );
            CREATE TABLE away_gaps        ( ... );
            CREATE TABLE sync_state       ( ... );
            """)
    }
}
```

> ⚠️ **Build-time check:** `sessions.client_id/project_id/task_id` reference `pd_*` tables that do
> not exist until Phase 2. Either create the FK columns **without** the `REFERENCES` clause in
> `v1-capture` and add the constraint when `pd_*` lands, or accept that `foreign_keys=ON` tolerates
> a reference to a not-yet-created table until first use — verify GRDB/SQLite behavior on the target
> and pick one ([data-model.md](../architecture/data-model.md#migrations) already flags this).

---

## Key references

- [../architecture/module-map.md](../architecture/module-map.md) — the eight targets, the acyclic
  dependency graph, and the protocol seams (`SecretStore`, `Clock`).
- [../architecture/data-model.md](../architecture/data-model.md) — DDL, PRAGMAs, migration rules.
- [../architecture/overview.md](../architecture/overview.md) — single-process model (G8) and the
  `SMAppService` launch-at-login snippet.
- [../build/signing-and-tcc.md](../build/signing-and-tcc.md) — stable identity, `Local.xcconfig`,
  why TCC grants die on signature change (G7).
- [../build/xcodegen-spec.md](../build/xcodegen-spec.md) · [../build/environment-setup.md](../build/environment-setup.md)
  — `project.yml` structure and first-generate.
- [../reference/macos-permissions-tcc.md](../reference/macos-permissions-tcc.md) — how `doctor`
  reads permission status.
- [../guardrails.md](../guardrails.md) — G6 (Keychain-only), G7 (stable signature), G8 (one process).

---

## Risks

- **Unstable signature strips TCC grants (G7).** The single most common way this class of app
  "mysteriously stops working." Wire the stable identity + fixed bundle id *now*, before any TCC
  feature exists, so Phase 1 inherits durable grants. Mitigation:
  [signing-and-tcc.md](../build/signing-and-tcc.md); `doctor` makes a lost grant visible.
- **Launch-at-login approval friction.** `SMAppService.mainApp.register()` can require the user to
  approve the item under System Settings → General → Login Items; surface `.requiresApproval` in
  `doctor` rather than assuming success (⚠️ build-time check the flow on the installed macOS).
- **Sandbox vs. capture.** App Sandbox blocks Accessibility + cross-app Automation; enabling it
  now would silently break Phase 1. Keep it off and document why in the entitlements file.
- **Headless `doctor` bootstrapping.** A `MenuBarExtra` app is `NSApplication`-based; a terminal
  `--doctor` run may need care to avoid spinning up the UI. Prefer a code path that builds
  `Diagnostics` without presenting the scene.
- **Config file location drift.** If `config.json` is expected in Application Support but a
  teammate drops it next to the binary, load fails opaquely. `doctor` must print the exact path it
  looked at.

---

## Acceptance criteria

Verbatim-faithful to [../../PLAN.md](../../PLAN.md) §11 Phase 0 — *"icon lives in the menu bar,
survives reboot, a `tidytime doctor` debug view shows DB path and permission status."* Each item is
human-verifiable:

- [ ] After `make run`, the **TidyTime icon is present in the menu bar** (and no Dock icon appears —
      `LSUIElement`).
- [ ] With launch-at-login enabled, the icon **reappears after a reboot** without manually
      launching the app.
- [ ] `make doctor` prints the **SQLite DB path**, and that file **exists** on disk at
      `~/Library/Application Support/TidyTime/tidytime.sqlite`.
- [ ] The in-app **Doctor view** shows the **config path** and a **per-permission status** block
      (Accessibility, Automation, Notifications, launch-at-login) plus the bundle id + signing
      identity.
- [ ] (supporting) The DB opens in **WAL** with the **`v1-capture`** migration applied; `config.json`
      loads; a dummy secret **round-trips** through the Keychain and never appears in logs.

---

## Definition of done

- `make build` compiles (Swift 6) and `make test` passes, including: a migration test (open a fresh
  DB, assert `v1-capture` applied and the five tables exist), a config-load test, and a
  `SecretStore` round-trip test.
- The app runs as a menu-bar-only agent; launch-at-login registers via `SMAppService.mainApp`.
- `make doctor` and the in-app Doctor view render the same `Diagnostics` (DB path, config path,
  permission status, launch-at-login, signing identity).
- Signing uses the stable identity from `Local.xcconfig`; `.gitignore` covers `config.json`, the
  DB, `Local.xcconfig`, and `secrets*` (guardrails G6, G7).
- No guardrail regression: no secret in config/DB/logs; no background daemon or helper target (G8);
  no capture/network code introduced.
- [data-model.md](../architecture/data-model.md) is unchanged (the DDL already matches
  `v1-capture`); [CLAUDE.md](../../CLAUDE.md)'s phase table links resolve to this file.
- All new files are under a target path XcodeGen sees; `make generate` regenerates cleanly.

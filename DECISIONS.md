# Decision & Learning Log

Append-only log of significant choices, non-obvious bug fixes, hard-won lessons, and abandoned
approaches. **Written for a future AI session with no memory of this one** — assume the reader has
the repo but not the conversation. Newest entries at the bottom of each phase.

Format per entry: **what** was decided/learned and **why**. Commit each entry with the work it
describes.

> Loaded by [CLAUDE.md](CLAUDE.md) — read this before starting work so you don't relearn or
> undo these decisions.

---

## Phase 0 — Test & debug infrastructure

### 2026-07-23 · Toolchain & the GRDB-vs-system-SQLite decision
- **Environment:** macOS 26.5.2, Swift 6.3.3, Xcode 26.6, target `arm64-apple-macosx26.0`.
  `FoundationModels.framework` IS present in the SDK (the on-device rung is buildable here).
- **Decision:** kept the plan's **GRDB** dependency. Verified `swift build` resolves GRDB 7.x over
  the network (GitHub reachable) and the whole package compiles (~157s first build).
- **Fallback recorded for a future worker:** the system `import SQLite3` module is also available
  (libsqlite3 3.51 in the SDK). If a future environment blocks network egress and GRDB can't be
  fetched, the store layer could be reimplemented on `SQLite3` directly with no external
  dependency. We did NOT do this because network works; noted so nobody re-discovers it under
  pressure.

### 2026-07-23 · Headless environment → what "implement + test" means here
- **Constraint:** this is a non-interactive session. We cannot grant Accessibility/Automation
  (TCC), run the GUI menu-bar app, complete OAuth, or hit live Productive/Fathom/Slack/Google APIs
  (no tokens; those MCP servers need interactive auth).
- **Strategy (applies to every phase):** put ALL logic in the `TidyKit` SwiftPM package behind
  protocols, and test it with fakes + in-memory GRDB via `swift test` (this genuinely runs).
  OS/UI integration (NSWorkspace, AXUIElement, Apple Events, SMAppService, MenuBarExtra,
  NSPasteboard, UNUserNotificationCenter, FoundationModels, live OAuth/HTTP) is written to
  **compile** (availability-guarded) but is exercised via its protocol's fake in tests. Acceptance
  criteria that require a running app or real permissions are verified **manually** and flagged in
  each phase's retrospective. The app shell (`App/`) is built by XcodeGen/xcodebuild, not by
  `swift test`, so its code is not unit-tested here — keep app-target code thin and delegate to
  tested `TidyKit` types.

### 2026-07-23 · Parallelization strategy
- **Decision:** coupled, must-compile-together Swift is written in the **main session** for compile
  coherence; parallel agents are used only for genuinely independent artifacts (the reference/docs
  build-out earlier, the final multi-agent review, the `/site` website).
- **Why:** parallel agents editing interdependent Swift risk a broken build that's expensive to
  reconcile, and the goal requires all commits + DECISIONS.md to route through the main session
  anyway.

### 2026-07-23 · Config decoding uses explicit snake_case CodingKeys (NOT convertFromSnakeCase)
- **Decision:** `Config` (TidyCore/Config.swift) decodes with hand-written `CodingKeys`, not
  `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase`.
- **Why:** `.convertFromSnakeCase` also transforms **dictionary keys**, which would corrupt
  `retention_days` (keys are table names like `activity_samples`) and `ai.routing`
  (keys like `session_batch`). A future worker "simplifying" this to the strategy will silently
  break dict-keyed config. Every sub-struct also implements `init(from:)` with `decodeIfPresent ??
  default` so partial/empty config still loads and unknown keys are ignored.

### 2026-07-23 · Logging + diagnostics design (the debug infra this project requires)
- **Dual-sink logging:** `TidyLogger` writes to Apple unified logging (`os.Logger`) AND a JSONL
  file (`FileLogSink`, size-rotated). Every message + field is passed through `Redactor` **before**
  write (guardrail G6). Sinks are injected so tests capture records in memory (`InMemoryLogSink`).
- **Diagnostic bundle (manual debug mode):** `DiagnosticsAssembler` (TidyStore) gathers env, config
  summary (non-secret), **credential NAMES only**, permission status, DB row counts, and recent log
  lines into a `DiagnosticsInput`; `DiagnosticsBundle.render` formats Markdown and scrubs the whole
  blob a final time. `ClipboardWriter` is a protocol — `SystemClipboard` (NSPasteboard, TidySurface)
  in the app, `FakeClipboard` in tests. `DebugModeTests` proves a seeded secret value never reaches
  the clipboard.

### 2026-07-23 · SwiftPM: exclude module README.md files
- **Learned:** a `README.md` inside a target's `Sources/<T>/` (or `Tests/`) dir makes SwiftPM warn
  "found N file(s) which are unhandled". Fix: add `exclude: ["README.md"]` to each target in
  `Package.swift`. Applied to all 9 targets.

### 2026-07-23 · BUG: `.gitignore` `secrets*` silently ignored `SecretStore.swift`
- **Symptom:** `git add -A` refused to stage `Packages/TidyKit/Sources/TidyCore/SecretStore.swift`;
  `git restore --staged` reported it "did not match any file(s) known to git".
- **Cause:** `.gitignore` had a bare `secrets*`. Git's `core.ignorecase` defaults to **true** on
  macOS's case-insensitive filesystem, so matching is case-insensitive: `secrets*` matches
  `secretstore.swift` because "secretstore" begins with "secrets" (s-e-c-r-e-t-s). The file was
  invisible to git with no error until an explicit stage attempt.
- **Fix:** replaced `secrets*` with specific names (`secrets.json`, `secrets.yaml`, `secrets.txt`,
  `.secrets/`). **Lesson for future workers:** never use broad, unanchored ignore globs that could
  collide with source filenames; prefer specific names or root-anchored patterns, and remember
  macOS git matching is case-insensitive.

### 2026-07-23 · Migrations: one per phase, never erase
- **Decision:** `Migrations.migrator()` registers `v1-core` (the `app_metadata` table) in Phase 0;
  each later phase appends its own migration (`v1-capture`, `v1-productive`, …). We do NOT enable
  `eraseDatabaseOnSchemaChange` (it would drop user data). Domain tables land in their phase, not
  up front, matching docs/architecture/data-model.md's phase map.

---

## Phase 1 — Capture

### 2026-07-23 · Sessionization algorithm & context keys
- **Context key** (`ContextKey.derive`): a browser sample keys on `web:<host>` (host lowercased,
  `www.` stripped); everything else keys on `app:<bundleId>`. This is the unit sessionization
  groups by and that entity resolution (Phase 5) will map to clients.
- **Sessionizer:** builds runs of one context, **absorbing a brief detour** only when it is shorter
  than `detour_tolerance_seconds` AND bounded by the same context on both sides (a real "glance
  away and come back"). Runs shorter than `min_session_seconds` are **dropped** — that sub-threshold
  time is recovered later as micro-work pools (Phase 5), not lost to a session row. `primaryApp` is
  the app with the most in-run duration. Deterministic; no clock dependency in the core.

### 2026-07-23 · Retention semantics
- **`RetentionJob.purge`** deletes rows **strictly older** than the window (`ts < now - days*86400`).
  A row exactly at the boundary is kept (a test initially failed by seeding a row at exactly 90d —
  the logic was right, the test data was off-by-one). `page_snapshots` cascade-delete with their
  `activity_samples` (FK `ON DELETE CASCADE`). Tables not yet created in earlier phases are skipped
  silently (checked against `sqlite_master`).

### 2026-07-23 · Cross-phase FK columns created without REFERENCES
- `sessions`/`away_gaps` carry `client_id`/`project_id`/`task_id`, which reference `pd_*` tables that
  don't exist until Phase 2. The `v1-capture` migration creates these as **plain columns** (no
  `REFERENCES` clause) so migration order stays valid. This matches data-model.md's note.

### 2026-07-23 · Live capture is compile-only; a runtime trap avoided in IdleReader
- `LiveCapture.swift` (ChromeAdapter via NSAppleScript, FrontmostReader via NSWorkspace+AX,
  AppWatcher, IdleReader, PowerObserver) is `#if canImport(AppKit)` and compile-checked but not
  unit-tested (needs a running app + TCC grants). Its logic is exercised via fakes elsewhere.
- **Bug avoided:** the common idle idiom `CGEventSource.secondsSinceLastEventType(_, CGEventType(rawValue: ~0)!)`
  force-unwraps an **invalid** `CGEventType` case and would **trap at runtime** on a real Mac (it
  only compiles). `IdleReader` instead takes the **min across concrete event types** (mouseMoved,
  keyDown, scrollWheel, …). Future workers: do not "simplify" back to the any-event raw value.

### 2026-07-23 · Swift 6 concurrency in notification observers
- `NSWorkspace`/`DistributedNotificationCenter` observer closures are `@Sendable`. Capturing a
  non-Sendable `() -> Void` helper closure inside them errors ("sending 'action' risks data races").
  Fix: inline each observer and capture only `[weak self]` (a `@MainActor` class is Sendable), then
  `MainActor.assumeIsolated { ... }` inside. Applied in `PowerObserver`.

---

## Phase 2 — Productive mirror (read-only)

### 2026-07-23 · Reusable ingest HTTP layer (used by Phases 2–4)
- `HTTPClient` protocol with `URLSessionHTTPClient` (live) and `FakeHTTPClient` (queued responses,
  records requests). `Backoff` (exponential + cap, honors `Retry-After`). The live client retries
  on **429** with an **injected `sleeper`** closure — tests pass `{ _ in }` so no real time passes.
  This is the pattern every API client reuses; don't hand-roll another.

### 2026-07-23 · JSON:API decoding — again, no `convertFromSnakeCase`
- `JSONAPIDocument`/`JSONAPIResource` decode with explicit `CodingKeys` on the attribute structs.
  `.convertFromSnakeCase` would mangle the **relationships dictionary keys** (`task_list` →
  `taskList`), breaking `relationshipId("task_list")`. Relationship `data` is a `.one`/`.many` enum
  that tries single-object then array. Same lesson as Config — do not switch to the strategy.

### 2026-07-23 · G1 (read-only Productive) enforced structurally + by test
- `ProductiveRequestBuilder.build(method:)` **throws `IngestError.readOnlyViolation` for any method
  other than GET**, and there is no public non-GET entry point (`get(...)` is the only public one;
  the `ProductiveClient` protocol has only `fetch*` methods). `ProductiveGuardrailTests` asserts
  POST/PATCH/PUT/DELETE all throw. A future write client (v2) must be a **separate type**, never a
  method added here.

### 2026-07-23 · Productive attribute/filter names are build-time checks
- Exact attribute names (`company_type_id`, `time`, `billable_time`) and filter keys
  (`filter[person_id]`, `filter[after]`, `filter[before]`, `filter[assignee_id]`) are what
  docs/reference/productive-api.md flagged as ⚠️ build-time checks. Test **fixtures reflect the
  documented shape**; the parser is tolerant (optionals). Confirm against the live API at
  integration and adjust `*Attrs`/query keys if they differ — the mapping is isolated in
  `ProductiveClient.swift`.

### 2026-07-23 · Misc
- `pd_time_entries` is **not** unique on `(person_id, date)` — a person logs many entries per day.
  Just an index for gap-analysis lookups.
- `NSLock.lock()/unlock()` are **unavailable from async contexts** in Swift 6; use
  `lock.withLock { }` inside `async` functions (applied in `FakeHTTPClient.send`).
- `resolveSelf(email:)` is case-insensitive and clears any prior `is_self` before setting the match.

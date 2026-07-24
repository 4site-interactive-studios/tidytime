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
  away and come back"). Runs shorter than `min_session_seconds` (default 60s) are **dropped as
  noise** — and, to be precise (a review corrected an earlier over-claim here): these sub-60s
  fragments are **NOT** recovered by pooling. Micro-work pooling (Phase 5) operates on sessions that
  *survive* the 60s floor but fall under the 15-min standalone threshold; genuinely tiny screen
  flickers are intentionally discarded. `primaryApp` is the app with the most in-run duration.
  Deterministic; no clock dependency in the core.

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

---

## Phase 3 — Meetings & calendar

### 2026-07-23 · Fathom: duration ground truth + build-time-check DTO shape
- Meeting **duration = recording span** (`recording_end − recording_start`), falling back to the
  scheduled slot. `Meeting.id` = stringified `recording_id`. Transcript timestamps parsed from
  `"HH:MM:SS"` → `start_seconds`. Summary read from `default_summary.markdown_formatted`. Response
  envelope `{ items, next_cursor }`. **All of these are ⚠️ build-time checks** (fathom-api.md) — the
  DTOs in `FathomClient.swift` are the single place to fix if the live API differs.
- `meetings.calendar_event_id` is left **NULL** — Fathom doesn't return the Google event id. A later
  step (Phase 5+) can match a meeting to a `calendar_events` row by time window + attendees.

### 2026-07-23 · Idempotent re-sync of meetings
- On re-sync, invitees and utterances are **replaced** (delete-by-meeting then insert), and the
  meeting's `kind='meeting'` session is **deleted by `source_ref` then re-inserted**, so re-running
  `FathomSync` never duplicates rows/sessions. Tested (`FathomSyncTests` runs sync twice).

### 2026-07-23 · Google Calendar specifics
- Google returns **camelCase** JSON, so its DTOs decode **without** CodingKeys/strategy (unlike
  Productive/Fathom). `status == "cancelled"` events become **deletions** (`CalendarPage.deletedIds`);
  others upsert. `is_external` per attendee via `internal_domains` (unknown domain → external,
  conservative). `conference_url` = `hangoutLink` else the first `video` conference entry point.
  Cursor is the `nextSyncToken`.
- **OAuth is behind a seam:** `LiveGoogleCalendarClient` takes an injected
  `accessToken: () async throws -> String`. The token exchange/refresh (loopback + PKCE, Internal
  client, refresh token in Keychain) is live-only and untested; request building + parsing are
  tested with a static token via the fake.

### 2026-07-23 · Away-prompt data path
- The away prompt is UI (Phase 6 surface), but its data operations exist now: `resolveAwayGap`
  (attribution + optional client/project) and `unresolvedAwayGaps`. Tested.

---

## Phase 5 — Recap & rules

### 2026-07-23 · Classification rungs 1–2
- **Rung 1 (rules):** exact match of a session's candidate values (web host, Slack conversation id,
  meeting invitee domains) against `entity_signals`. User-confirmed signals outrank inferred; a
  match yields confidence 0.85 (inferred) / 0.97 (user-confirmed).
- **Rung 2 (lexical):** token-overlap of the session (title + host + invitee domains) against a
  candidate index built from company/project/task names. Tie-break prefers the **less specific**
  candidate (company over project over task) to avoid over-committing; if a **different client**
  ties at the top score it's ambiguous → return nil (becomes a resolution question). Confidence
  `min(0.8, 0.45 + 0.12·score)`.
- **EntityBootstrap** seeds `url_host` + `email_domain` signals from company domains so a session on
  a client's site resolves at rung 1 for free.

### 2026-07-23 · RoundingPolicy
- `floor(units + roundUpBias)` with a **minimum of one increment** for any kept item, so 6 real
  minutes → 15 (flagged `is_rounded_up`), matching the plan's meeting-split example. Bias 0.4 rounds
  up once the fractional part exceeds 0.6.

### 2026-07-23 · Pooling rolls up EVERYTHING at recap (test-driven correction)
- Two-level: sessions aggregate into groups by task→project→client; a group **at/over** the
  standalone threshold becomes a suggestion, a **sub-threshold** group pools per project.
- **Correction:** initially pools only rolled up at ≥15 min, which meant scattered <15-min project
  work silently evaporated — the exact failure pooling exists to prevent. Since `generate()` IS the
  recap run, it now rolls up **every non-empty pool** ("or at recap time", PLAN §8). The
  `poolThresholdMinutes` param is retained for a future real-time promotion path. A test asserting
  the old behavior forced this fix.

### 2026-07-23 · Gap analysis, new-task, learning, sensitivity
- **Gap analysis:** per-task logged minutes (from `pd_time_entries`) are subtracted from a task
  group's rounded minutes; a fully-logged task is skipped (`skippedAlreadyLogged`).
- **New-task proposals:** a client/project group with no task → `kind='new_task'` with a proposed
  title from the session.
- **Learning:** a **reassign** decision writes a `user_confirmed` signal (outranks inferred forever);
  `DayClassifier` strengthens matched signals as `inferred`.
- **SensitivityGate** (G2) fails closed: case-insensitive substring match against configured
  keywords + flagged people/terms; `gated()` returns nil for sensitive text. Used by Phase 6 before
  any cloud send.
- `RecapAssembler` builds the tested read model + daily rollup; `RecapView` (SwiftUI) is compile-only.

---

## Phase 6 — Intelligence

### 2026-07-24 · AIRouter: the single metered call site (G2 + G5)
- **Fixed order, never reordered:** sensitivity gate → resolve route → budget check → record
  outbound payload → provider call → write `ai_calls` row. There is **no** code path to a provider
  that skips the gate or the ledger.
- **G2:** sensitive `userPrompt`/`systemPrompt` → `refused_sensitive` ledger row, provider **not
  called**, and the content is **never** handed to `OutboundPayloadRecorder`. `AIRouterTests`
  seeds "PIP"/"salary" and asserts they appear in **no** recorded payload — this is the phase's G2
  acceptance test.
- **G5:** every outcome writes a row (`ok`/`error`/`refused_sensitive`/`refused_budget`). Budget is
  checked **before** dispatch against today's `ai_calls` spend (per-provider + global); over cap →
  `refused_budget` (local-only). Cost computed from the config price table.

### 2026-07-24 · Providers
- **Fireworks** = OpenAI-compatible `/chat/completions` with `response_format: json_schema` when a
  schema is supplied; usage → tokens. **Anthropic** = `/messages`; the structured-output request
  shape is a ⚠️ build-time check, so we pass any schema **inside the system prompt** and read the
  text back rather than gambling on `output_config`. Both reuse TidyIngest's `HTTPClient`.
- **Apple on-device** (`AppleOnDeviceProvider`) IS wired to the real Foundation Models API —
  `SystemLanguageModel.default.availability == .available`, `LanguageModelSession(instructions:)`,
  `session.respond(to:).content`. It **compiles against the shipped macOS 26 SDK** and is
  runtime-gated (`#available(macOS 26.0)` + availability check); on an older OS / Apple Intelligence
  off it throws, and the router treats that as fall-through. Token counts aren't exposed → 0 (it's
  free anyway). Guided generation with `@Generable` is the remaining refinement (build-time).

### 2026-07-24 · Dependency deviation + misc
- **TidyAI now depends on TidyIngest + TidyUnderstand** (not just Core+Store as the module-map drew):
  it reuses the `HTTPClient`/`Backoff` layer for cloud calls and the `SensitivityGate`. Still acyclic
  (TidyAI→TidyIngest/TidyUnderstand→Store/Core). Recorded so the map can be updated.
- `Config.AI` gained a `budget` block (`daily_cap_usd`, `global_daily_cap_usd`) — it had been
  omitted in Phase 0 and is needed by `BudgetPolicy`.
- `NudgeEngine` is a pure decision (meeting-aware, quiet-hours wrap, daily cap, sustained-block,
  already-logged, dismissal-backoff that raises the confidence bar then mutes). Dashboard aggregates
  `ai_calls` (spend by job/provider, escalation rate, on-device share) + CSV export.

---

## Project-wide review (2026-07-24)

Three independent reviewers (correctness / coverage / plan-adherence) audited the finished
codebase — all returned `pass_with_concerns`. Full write-up + dispositions:
[docs/PROJECT-REVIEW.md](docs/PROJECT-REVIEW.md). Two were **real guardrail gaps** that were
configured/documented but not enforced, now fixed **with regression tests**:
- **G9:** `transcript_utterances` was never actually purged (no absolute timestamp column) — now
  purged via the parent meeting's `recording_start`/`fetched_at`.
- **G2:** the `SensitivityGate` failed **open** on an empty term list — now unions config terms with
  a hardcoded `floorTerms` floor, so a default/empty config still blocks sensitive content.

**Lesson for future workers:** "configured" ≠ "enforced." Both gaps had a config entry and a doc
promise but no test — so they silently did nothing. If a guarantee matters, write the test that
fails when it's broken. Other fixes: gap-analysis remainder stays on a 15-min increment (subtract
before rounding; sub-threshold remainder skips); the learning loop strengthens the **actual**
matched signal type (not a hardcoded `url_host`); the AI budget window is the **local** day; added a
G3 `CGWindowList` lint test and coverage for the Anthropic provider, `meeting_segment`, Fireworks
structured output, RecapAssembler logged-minutes, and the CSV export. 117 → 130 tests, all passing.

---

## Phase 4 — Slack

### 2026-07-23 · Slack ingest shape
- Read-only via an internal app's **user token** (Bearer). `slack_messages` is `UNIQUE(conversation_id,
  ts)`; upsert = `insert(onConflict: .replace)`. Conversation type derived from
  `is_im`/`is_mpim`/`is_private`/`is_channel`. `is_self` = message `user` == `auth.test` user id
  (this is what catches phone-sent Slack). Cursor = latest `ts` per conversation in
  `sync_state("slack:<id>")`, passed as `oldest`. The **internal-app exemption** from the May-2025
  rate limits is a ⚠️ build-time check.

### 2026-07-23 · SlackSessionizer + idempotent rebuild
- Messages cluster into `kind='slack'` sessions, split when the gap exceeds `gapSeconds` (default
  15 min). A single-message cluster gets a `nominalSeconds` duration (default 60) so drive-by help
  isn't zero-length. Re-sync deletes a conversation's slack sessions (`source_ref`) and rebuilds
  from **all** stored messages — idempotent.

### 2026-07-23 · LESSON: retention target tables accumulate across phases
- `RetentionTests.testSkipsUnknownOrAbsentTables` (written in Phase 1) broke when Phase 4 added
  `slack_messages` — it's now a real retention target, so purging it returns `0`, not `nil`. Fixed
  by testing skip-logic against a **truly nonexistent** table name and adding a positive
  slack-purge test. **Lesson:** when a phase adds a table listed in
  `RetentionJob.timestampColumns`, expect earlier "absent table" assumptions to change.

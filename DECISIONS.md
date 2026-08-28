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

## Post-v1 enhancement — tiered heartbeat (2026-07-24)

### Tiered, change-gated capture for sub-app granularity
- **Problem:** the original design sampled on app-**activation** events + a single 30s heartbeat.
  Switching *within* one app (chat 1 → chat 2 in Claude, or tab → tab in Chrome) fires no OS event,
  so it was only visible at heartbeat resolution and merged into one block.
- **Fix:** `CaptureCoordinator` (TidyCapture) runs two cadences, both **change-gated**:
  - **detection tick** (`poll`, fast — default 1s + on every app-activation): reads frontmost app +
    window title, and for a browser the active-tab URL/title (cheap). Records a NEW `activity_samples`
    row **only when the signature `(app, windowTitle, url)` changes** — so idle polling doesn't bloat
    the DB, but a within-app title/tab switch creates a distinct sample the instant it differs.
  - **content tick** (`captureContent`, slow — default 20s + once on a browser change): the expensive
    `document.body.innerText` capture, deduped by content hash.
- **Config:** added fractional `capture.detection_interval_seconds` (Double, default 1.0) and
  `capture.content_interval_seconds` (Double, default 20.0). `heartbeat_seconds` (Int) kept as a
  legacy field. The two-timer live wiring is `LiveCaptureController` (compile-only); the coordinator
  logic is fully tested (`CaptureCoordinatorTests`, incl. the within-app title-change case). 135 tests.
- **Known limits (documented, not fixed here):** (1) `min_session_seconds` (60s) still drops
  sub-minute runs as noise, so per-chat blocks under a minute won't survive unless that floor is
  lowered; (2) distinguishing chat 1 vs chat 2 still requires the app's **window title/AX to actually
  differ**; (3) at sub-second intervals the AX/AppleScript reads should move off the main thread with
  a timeout (noted in `LiveCaptureController`). For true event-accuracy without polling, an
  `AXObserver` on focus/title-change notifications is the better long-term path.

### Context-switching metric (2026-07-24)
- **Why:** agentic AI tools (many chats / Cowork / Claude Code + IDE + terminal + Slack) drive a lot
  of context switching; the user wants it quantified.
- **Key design:** `ContextSwitchAnalyzer` (TidyStore) computes from the **raw `activity_samples`
  stream**, NOT from `sessions`. This deliberately sidesteps the `min_session_seconds` (60s) floor —
  billing/attribution keeps filtering sub-minute noise, while the metric counts **every** switch,
  including the thrash. So we did NOT lower the noise floor; the two concerns read different data.
- **Signature = `(app, window_title, url)`** (same fine key the tiered coordinator records on), so
  within-app switches (chat→chat) count. Metrics: switch count, switches/active-hour, mean/median
  dwell, brief-switch count + fragmentation (%< 2min), unique contexts, longest focus.
- **Surfaced + persisted:** `RecapDay.contextSwitches` (on-demand) and a `v2-context-switches`
  migration adding `context_switches` / `brief_switches` / `longest_focus_seconds` to `daily_rollups`
  for trend history. Shown in `RecapView`. Tested (`ContextSwitchTests`, incl. within-app thrash).

### AI routing: everything through Fireworks (2026-07-24)
- **Decision:** ALL cloud inference — economy *and* escalation — routes through **Fireworks AI**
  (one vendor, one key, one ledger). Config-only change (`ai.routing.escalation` → a Fireworks
  model); the router already resolves job→model→provider from config, so **no code change**.
- **Honest caveat** (baked into config `_build_time_checks`): Anthropic's Claude/**Fable** are
  proprietary and **not served on Fireworks**, so the escalation rung uses a stronger **open-weight**
  model on Fireworks (DeepSeek-V3 placeholder — pick the best adjudicator at build time), NOT Claude.
  The `anthropic-claude` entry + `AnthropicProvider` remain as an **optional direct-API path** (needs
  a separate Anthropic key); enabling it is a one-line routing change. That direct path is the only
  way to get Claude/Fable-grade adjudication if it's ever required.

---

## Round-2 review fixes (2026-07-25)

Four **blind** reviewers audited `034e6b8..dcffdac` (the post-review delta, incl. the never-reviewed
site commit). 52 findings; 3 of 4 verdicts were `fail`. All four caught their calibration probes, so
the instrument was trusted. Fixes:

### ONE context signature, shared across three call sites (R1-1 / R3-7) — HIGH
- **Was:** `CaptureCoordinator.signature` and `ContextSwitchAnalyzer.signature` keyed on the **raw**
  URL and **raw** title, while `ContextKey` normalized both. So `?msg=1 → ?msg=99`, a `#fragment`, a
  trailing slash, or an unread-badge tick `(3) Slack → (4) Slack` wrote a NEW `activity_samples` row,
  re-fired the expensive `innerText` AppleScript, **and counted as a context switch** — inflating the
  exact metric the feature exists to report (a reviewer measured 10 churn samples → switchCount 9,
  fragmentation 100%, while sessionization correctly produced ONE session).
- **Now:** `TidyCore.ContextSignature` is the single definition (TidyCore because `TidyStore` cannot
  import `TidyCapture`). `ContextKey` forwards to it. `ContextSignatureTests.testCaptureAndMetricAgreeOnEveryCase`
  is a table-driven guard that fails if they ever re-diverge.
- **`ContextKey.derive` still uses `host(from:)`, NOT `normalizedURL`** — the latter falls back to the
  raw string for unparseable input and would yield `web:not a url` instead of the `app:` fallback.
- **Store raw, gate normalized:** `activity_samples.url` keeps the RAW URL (the ledger stays raw, so
  the metric can be recomputed under a future policy across the 90-day window); only the change gate
  and the metric normalize. `poll()` gained a *refresh-without-recording* branch so page snapshots
  still file under the on-screen URL.
- **Identity query params are an opt-in allowlist** (`capture.identity_query_keys`, default `[]`).
  A denylist of volatile params (`?msg=`, `utm_*`, …) would fail **open** — any unlisted param
  silently reintroduces the bug. An allowlist fails **closed**.

### Unattended time is not focus (R1-2) — HIGH
- **Was:** `closeOpenSample` makes samples contiguous *by construction*, so `AwayGapDetector.idleGaps`
  can never fire on recorder output, and `PowerObserver` is never constructed — an overnight absence
  rendered as one enormous run that won `longestFocusSeconds` and inflated `activeSeconds`.
  `writeRollup` then **persisted** it, poisoning the trend series permanently.
- **Now:** `analyze(_:now:awayGaps:)` clips runs against recorded away gaps (precise), plus a
  **generous fallback ceiling** `maxPlausibleFocusSeconds` (default 2h) for when no gap evidence exists.
- **DESIGN ERROR I made and corrected:** my first cut dropped any span ≥ `idleThreshold` (10 min).
  That is wrong — span length alone cannot distinguish deep focus from an idle machine, and it broke
  an existing test where one hour of genuine focused work stopped counting as focus. **Do not
  re-tighten this to idleThreshold.** `testOneHourOfDeepWorkStillCountsAsFocus` guards it.
- A trailing OPEN sample is clamped to `now`, so assembling a PAST day can't stretch a run to the present.

### Escalation rate corrupted by same-vendor routing (R3-1) — HIGH
- Routing escalation onto Fireworks broke `DashboardBuilder`, which classified the economy tier by
  `provider == "fireworks"` — so escalations were counted **inside their own denominator**. Tier is a
  **job** property, not a vendor one; now keyed on `jobType == "escalation" || outcome == "escalated"`.

### Page text scoped to the session's own context (R1-3) — MED
- `pageTexts` filtered on TIME only. A ≤120s detour that the Sessionizer *absorbs* into a session fell
  inside the window and — because ordering is newest-first with limit 3 — could supply **100%** of a
  two-hour session's attribution evidence. Now takes a `host:` scope; added an index on
  `page_snapshots(captured_at)` (R1-6, was a full scan + temp B-tree per session).

### Also fixed
- `captureContent()` now fires only when the **page** changed, not on any signature change (R3-6).
- `separate_chats_by_path` / `identity_query_keys` are read in production via
  `ContextSignature.Policy(config.capture)` in `LiveCaptureController` (R1-7 "configured ≠ enforced").
- **v2 migration upgrade path is now tested on a POPULATED db** (`migrate(upTo: "v1-ai")` → insert a
  rollup → migrate the rest), not just a fresh one (R2-02).
- Replaced a **vacuous assertion** (`testNativeSameTitleCannotSeparate` compared a pure function's
  output to itself) with a concrete expected value (R2-04).
- 152 → **184 tests**, 0 failures. Coverage 82.16% line on `Sources/`.

---

## App wiring + dmg (2026-07-25)

### The app shell now actually hosts TidyKit
- `App/TidyTimeApp.swift` was a placeholder for the whole build (every retrospective flagged it).
  It now constructs **`AppEnvironment`** (TidySurface) → opens the DB + migrations, loads config,
  wires `KeychainSecretStore` + `FileLogSink`, starts `LiveCaptureController`, and runs the local
  pipeline (`SessionBuildJob.rebuild` → `DayClassifier` → `RecapAssembler` → `RetentionJob`) on a
  5-minute timer. Launch-at-login via `SMAppService` (no helper, no launchd plist — **G8**).
- **`AppEnvironment` lives in TidySurface, not `App/`** — inside the SwiftPM package it can be
  compiled and partly tested; the app target stays a thin `@main` that only does what can't be
  tested headlessly (window management, `@main`, SMAppService).
- Full surface added: `MenuBarPopover`, `RecapWindow` (live wrapper over the pure `RecapView`,
  wiring actions → `decisions` + `suggestions.status`), `DashboardView`, `SettingsView`,
  `DoctorView`, `AwayPromptView` + `AwayGapResolver`, `NudgePresenter`.
- **`SessionBuildJob.rebuild`** was added because `run` *appends* — calling it repeatedly on a live
  day duplicated sessions. `rebuild` deletes the window's `kind='screen'` sessions first, leaving
  meeting/slack sessions (owned by their own sync jobs) alone.
- `PermissionInspector` reports TCC status **without prompting** (`AXIsProcessTrusted`,
  `AEDeterminePermissionToAutomateTarget(..., askUserIfNeeded: false)`); prompting is a separate,
  explicit button. Screen Recording is never inspected or requested (**G3**).
- Swift 6 note: `kAXTrustedCheckOptionPrompt` is a global `var` and is **not** concurrency-safe to
  reference; use the literal `"AXTrustedCheckOptionPrompt"` key instead.

### BLOCKER for a future worker: xcodebuild is broken on this machine (not the project)
- `xcodebuild` fails before compiling anything with:
  `DVTPlugInLoading: Failed to load code for plug-in com.apple.dt.IDESimulatorFoundation …
   Symbol not found: …DVTDownloads…`
- **Cause:** `/Library/Developer/PrivateFrameworks/DVTDownloads.framework` is dated **Jan 20 2026**
  — a stale *system* component from an older Xcode — while the installed Xcode is 26.6.
- **Fix (needs the user's password, so an agent cannot run it):** `sudo xcodebuild -runFirstLaunch`.
- **Workaround that proves the code is fine:** `make typecheck-app` /
  `scripts/typecheck-app.sh` type-checks `App/*.swift` with `swiftc -typecheck -parse-as-library`
  against the real SDK and the built TidyKit `.swiftmodule`s, bypassing xcodebuild's plugin loader.
  It passes. (Two gotchas baked into the script: pass GRDB's `GRDBSQLite` module.modulemap via
  `-Xcc -fmodule-map-file=…`, and `-parse-as-library` or a single-file compile rejects `@main`.)
- So: the app-shell code **compiles**; producing an actual `.app`/`.dmg` still needs a working
  xcodebuild + a `DEVELOPMENT_TEAM`. `make dmg` (`scripts/make-dmg.sh`) is written and refuses
  early with a clear message if `Local.xcconfig` is missing. It is **unrun**.

### dmg packaging
- `scripts/make-dmg.sh`: xcodegen → `xcodebuild -configuration Release` → stage app + an
  `/Applications` symlink → `hdiutil create -format UDZO`. Unsigned-by-Apple (no paid account), so
  first launch needs right-click → Open or `xattr -d com.apple.quarantine`. Documented in the script
  output itself, not just in a doc.

### Finer within-app attribution (2026-07-24)
- **Goal:** make each switched-to context (chat 1 vs Cowork vs a project, all inside one Claude
  window) land on the right client/project — not just be *counted* as a switch.
- **Two-level context key** (`ContextKey`): `derive` stays **coarse** (`web:host` / `app:bundle`) and
  is what's stored in `sessions.context_key` + used by rung-1 domain rules; new `grouping` adds a
  **normalized window/tab title** discriminator (`app:bundle#tidytime build`). The `Sessionizer` now
  groups by the fine `groupingKey` (via a new `SampleSlice.groupingKey`, defaulting to `contextKey`
  so existing behavior/tests are unchanged), while the session still stores the coarse key. Net: a
  within-app title change forms a **distinct session** that can attribute independently.
- **Title normalization** strips a leading unread badge like `(3) ` (so a changing count doesn't
  fragment the session), lowercases, collapses whitespace, truncates. Over-fineness is absorbed by
  the min-session floor / pooling / ask-once.
- **Page text into classification:** `DayClassifier` now fetches `page_snapshots` within a session's
  window (`db.pageTexts(from:to:limit:)`) and passes them to the classifier's rung-2 lexical (which
  already accepted `pageTexts` but was being handed `[]`). Local-only — rungs 1–2 don't hit the cloud,
  so no sensitivity gate needed here. A generic-title session now attributes via its page content.
- Tested: `FinerAttributionTests` (grouping split, two clients from two titles in one app, page-text
  attribution) + `GroupingKeyTests`. 141 → 147 tests.
- **Still coarse by design:** rung-1 domain rules key on host/bundle (a client's site resolves the
  same on any page); the *title/page-text* (rung 2) is what disambiguates which project within a tool
  like Claude. The `context_switches` metric remains independent (raw samples, finest granularity).

### Separate distinct chats within the same title (2026-07-24)
- **Want:** two Claude chats that share a title (e.g. both "New chat") should be distinct sessions.
- **How:** `ContextKey.grouping` now folds the browser **URL path** into the fine grouping key when
  `capture.separate_chats_by_path` is on (default true). The path carries the chat/doc id
  (`claude.ai/chat/<id>`), so same-title-different-chat → distinct sessions. **Query + fragment are
  dropped**, so per-*message* churn (`?msg=…`, `#anchor`) does NOT re-fragment (avoids the
  per-message explosion). The **coarse `context_key` is unchanged** (`web:host`), so rules and
  ask-once still key on the host and converge — exactly the two-altitude split from the prior entry.
- **Limits (documented):** native apps have no URL, so two same-title native chats still merge (needs
  app-specific AX). Path inclusion also separates a client site by page — harmless for attribution
  (same coarse host rule), absorbed by detour/pool/floor for density; toggle off for title-only.
- Tested: `FinerAttributionTests` (path split, query/fragment merge, toggle off, native merge, +
  a SessionBuildJob split). 147 → 152 tests.

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

---

## Keychain persistence across rebuilds (2026-07-25)

### Tokens survive a reinstall; the risk is ACL, not storage
- Items are `kSecClassGenericPassword` keyed on `kSecAttrService = "com.4site.TidyTime"` (a **fixed
  string**) + account. They live in the user's login keychain, **not** in the app bundle — so
  deleting/replacing `TidyTime.app`, or installing a fresh dmg, does **not** delete them. The lookup
  still finds them.
- What *can* break is the **ACL**. The app is non-sandboxed, so each item carries a trusted-app list.
  A build with a **different code signature** (unsigned preview, or before `DEVELOPMENT_TEAM` was
  set) is a different identity → macOS prompts ("wants to use your confidential information") or
  returns `errSecAuthFailed`.
- **Practical rule:** with a stable `DEVELOPMENT_TEAM`, rebuilds reuse the tokens silently. With
  unsigned/ad-hoc builds, expect a prompt per new binary. Same root cause as the TCC/G7 problem —
  signature stability — so fixing signing fixes both.

### BUG FIXED: `set()` couldn't recover from an ACL mismatch
- `SecItemUpdate` failing with anything other than `errSecItemNotFound` used to throw immediately.
  So a user whose item belonged to a differently-signed build could neither READ the token nor
  OVERWRITE it from Settings — a dead end whose only exit was Keychain Access.app.
- Now: on `errSecAuthFailed` / `errSecInteractionNotAllowed` / `errSecDuplicateItem`, delete the item
  and re-add it, and if that still fails, throw a message naming the actual cause and the manual fix.
- ⚠️ **Untested against the real Keychain** — unit tests use `InMemorySecretStore` (the real Keychain
  is environment-dependent and prompts). Verifying this needs two differently-signed builds on a real
  Mac; it is reasoned from documented Security-framework behavior, not observed.

### 2026-07-25 · Slack app manifest was rejected as "invalidly formatted"
- **Reported by the user** when following docs/permissions-setup.md §8.
- **Causes (the doc's own ⚠️ build-time check firing):** (a) the doc led with a **YAML** manifest
  containing `#` comments, but Slack's current editor is **JSON-only**; (b) the JSON variant carried
  optional fields (`description`, `background_color`, `settings.interactivity`) and omitted
  `settings.is_hosted`, diverging from Slack's own reference structure.
- **Fix:** replaced both with ONE minimal JSON manifest mirroring Slack's reference exactly, and
  added a **From scratch** fallback (add the ten user scopes in the UI), which bypasses manifest
  validation entirely and surfaces a bad scope name individually rather than as an opaque failure.
- A test-free doc assertion is still an assertion: a `python3 -c json.loads` check over the block was
  run before committing so at least the syntax can't regress silently.
- **Lesson:** vendor manifest schemas drift and validators are opaque. Prefer the smallest manifest
  that expresses intent, and always document the UI fallback.

### 2026-07-25 · FIRST RUN of the app — and a Google credential gap it exposed
- **The app launched for the first time** (user screenshot): Settings window renders, the Credentials
  pane lists `SecretKey.all`, and Keychain writes succeed (5 of 6 stored). Large amounts of
  previously "compile-only, never executed" code — AppEnvironment startup, DB open + migrations,
  SettingsView, KeychainSecretStore.set — are now known-good at runtime.
- **Gap found by the user:** permissions-setup.md said to put "the Client ID (and client secret)"
  into "the app's Google config", but there was **nowhere for the client secret** — `config.google`
  has only `client_id/calendar_id/scopes/internal_domains`, and `SecretKey` had no client-secret
  entry. The instruction was impossible to follow.
- **Fix:** added `SecretKey.googleClientSecret = "google.client_secret"` (appears in the Settings
  picker automatically, since the UI iterates `SecretKey.all`), and rewrote the doc step as an
  explicit three-way table: client id → `config.json`, client secret → Keychain, refresh token →
  **output of the OAuth flow, never pasted**.
- **Still true:** none of this is usable yet — there is no OAuth implementation, only the injected
  `accessToken` closure in `LiveGoogleCalendarClient`. Storing the client id/secret is preparation.

### 2026-07-25 · First-run diagnostics exposed: ingest was never wired into the app
- **Symptom (from a real diagnostic bundle):** capture worked — 378 `activity_samples` → 22
  `sessions` — but `sync_state`, every `pd_*`, and `slack_messages` were **0** despite the user
  having stored Productive/Fathom/Slack tokens.
- **Cause:** when the app shell was wired (`b5db65a`) I connected capture + the LOCAL pipeline
  (`SessionBuildJob` → `DayClassifier` → `RecapAssembler` → `RetentionJob`) but **never constructed
  `ProductiveSync` / `FathomSync` / `SlackSync` / `CalendarSync`**. Nothing called them, so tokens
  sat unused. A grep for those types across `Sources/TidySurface` + `App/` returned nothing.
- **Fix:** `IngestCoordinator` (TidySurface) + a 15-minute timer in `AppEnvironment`. Crucially it
  exposes a **pure, network-free `readiness(_:)`** that says *why* a source isn't running —
  `missingCredential` / `missingConfig` / `disabledByKillSwitch` / `notImplemented`. Doctor renders
  it, so a zero table now explains itself instead of looking broken. One failing source is logged to
  `sync_state.last_error` and never blocks the others.
- **Also fixed:** the diagnostic bundle's config summary still reported the legacy `heartbeat_s`
  instead of the real `detection_interval_s`/`content_interval_s` — actively misleading in the one
  artifact used for debugging. A test now asserts the legacy key is absent.
- **Lesson (third instance this session):** "the module exists and is tested" ≠ "the app calls it."
  Capture, `separate_chats_by_path`, and now all four ingest engines each shipped tested-but-unreached.
  When wiring an app shell, enumerate every engine and assert a production construction site exists.

### 2026-07-25 · G7 confirmed in the wild: ad-hoc signature silently voids TCC grants
- **Symptom:** the user granted Accessibility, System Settings showed it enabled, but Doctor kept
  reporting `not granted` and no window titles were captured.
- **Evidence** (`codesign -dv` on the installed app):
  `flags=0x20002(adhoc,linker-signed)`, `Signature=adhoc`, `TeamIdentifier=not set`,
  and `Identifier=TidyTime` (not `com.4site.TidyTime` — a linker-signed default, so even the
  identifier TCC records differs from the bundle id).
- **Mechanism:** macOS records a TCC grant against the app's code-signing identity. Ad-hoc builds
  have no stable identity, so the recorded grant does not match the running binary —
  `AXIsProcessTrusted()` returns false while the UI toggle still shows ON. **This is exactly the
  failure guardrail G7 exists to prevent**, observed for real rather than predicted.
- **Fix for the user:** remove the stale System Settings entry, set `DEVELOPMENT_TEAM` in
  `Local.xcconfig`, rebuild with `make dmg` (signed), reinstall, re-grant.
- **Fix in the product:** `PermissionInspector.signatureStatus()` now reads the running bundle's
  signing info via `SecCodeCopySigningInformation` and Doctor shows
  `⚠️ AD-HOC … TCC grants will NOT persist; set DEVELOPMENT_TEAM`. The condition is no longer
  invisible — the app diagnoses it.
- **Lesson:** a guardrail documented but not *surfaced at runtime* still costs the user an hour.
  Where a misconfiguration produces a confusing symptom, make the app say so.

### 2026-07-25 · `tidytime-doctor` CLI — diagnostics without a human in the loop
- **Why:** troubleshooting required the user to open the app, click "Copy diagnostics", and paste.
- **What:** a new executable target (`swift run tidytime-doctor` / `make diagnose`) prints the same
  redacted bundle. It opens the DB **read-only** (`AppDatabase.openReadOnly`, no migrations) so it can
  never mutate a database the app has open; WAL permits the concurrent reader.
- **Deliberate split, and the subtle part:** TCC status is **per-binary**, so the CLI asking about
  Accessibility would report the *CLI's* answer, not the app's — actively misleading. Instead the
  running app writes a redacted snapshot to `~/Library/Application Support/TidyTime/diagnostics.md`
  on every pipeline pass, and the CLI reports the app's permission lines from that snapshot plus its
  age. Live DB/config/logs come from the direct read.
- `--snapshot` prints the app's snapshot verbatim; `--log-lines N` controls log tail depth.

### 2026-07-26 · Signing resolved — and two false leads worth recording
- **Outcome:** the app is now signed with a stable Apple Development identity
  (`TeamIdentifier=QCUYJGV4J5`, `Identifier=com.4site.TidyTime`, chains to Apple Root CA, satisfies
  its Designated Requirement). `dist/TidyTime.dmg` is a properly signed build; TCC grants will now
  persist across rebuilds (G7).
- **BUG in `find-team-id.sh` #1 — `-v` produces false negatives.** `security find-identity -v -p
  codesigning` reported "0 valid identities" while a perfectly usable Apple Development certificate
  existed (it had been created minutes earlier; `security verify-cert -p codeSign` succeeded on it).
  The script now queries WITHOUT `-v` and verifies explicitly. This false negative sent a real user
  round in circles re-doing Xcode steps that had already worked.
- **BUG in `find-team-id.sh` #2 — the team id is the subject's `OU`, NOT the CN parenthetical.**
  For `CN=Apple Development: … (QS9XD22TCK), OU=QCUYJGV4J5`, the DEVELOPMENT_TEAM is **QCUYJGV4J5**.
  The original script grabbed the parenthetical (the *certificate* id) and would have written the
  wrong value, producing a confusing signing failure. Now extracted via
  `openssl x509 -noout -subject | grep -oE 'OU=[A-Z0-9]{10}'`.
- **Self-signed fallback: works, but wasn't needed.** Creating one via OpenSSL 3.x requires
  `-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1`, or `security import` fails with
  "MAC verification failed … (wrong password?)" — OpenSSL 3's default PKCS#12 MAC is rejected by
  macOS. An imported self-signed cert also shows `CSSMERR_TP_NOT_TRUSTED` until trust is added.
  The temporary cert was deleted once the Apple identity was confirmed.

---

## Google OAuth + first-live-run fixes (2026-07-27)

### Google OAuth flow (loopback + PKCE) — contract verified against Google docs 2026-07-26
- `ContextGoogleOAuth`: PKCE S256 (RFC 7636 Appendix B vector in tests), auth URL, code exchange,
  refresh; `GoogleTokenProvider` actor fills the `accessToken` closure `LiveGoogleCalendarClient`
  has had since Phase 3; refresh token in Keychain, access token cached to 60s before expiry.
- **`prompt=consent` is opt-in, not default** — Google always returns a refresh token to installed
  apps; unconditional consent would re-prompt every sign-in (verification agent caught my bug).
- **`client_secret` sent on both token calls** (⚠️ build-time check: docs label it Optional but the
  live endpoint reportedly rejects secret-less desktop exchanges). `127.0.0.1` not `localhost`.
  Internal-type consent screen ⇒ NO 7-day refresh expiry. `invalid_grant` on refresh = terminal →
  clear token, re-auth. Errors mapped: admin_policy_enforced / org_internal / disallowed_useragent.
- **`NWListener` fails with EINVAL in this environment** (verified with a standalone probe, both
  with and without `requiredInterfaceType=.loopback`) while raw BSD sockets work → LoopbackReceiver
  is BSD sockets bound to INADDR_LOOPBACK explicitly. 
- **`shutdown()` before `close()`** on the listening fd: on macOS close() alone does NOT reliably
  wake a thread blocked in accept() — this exact hang left an xctest alive 13h46m.

### The build-wedge epidemic, finally diagnosed
- Symptom: every `swift build`/`swift test` "hung" for hours over two days.
- Root cause: ONE hung xctest (LoopbackReceiver's pre-fix accept() deadlock) held the SwiftPM
  package lock for ~14 HOURS; every subsequent build parked in mach_msg behind it. My cleanup kills
  grepped only `swift-build|swift-frontend` — never `swift-test`/`xctest` — so the true holder
  survived every purge, and each killed-while-queued build left another wedged driver behind it.
- Lessons: (1) `ps` + `sample <pid>` + `lsof +D .build` beats guessing; 0% CPU + mach_msg = lock
  wait, not compilation. (2) Grep the whole process FAMILY. (3) A python `str.replace` that prints
  "done" unconditionally is a silent no-op waiting to happen — use the Edit tool (fails loudly) or
  verify the substring changed.

### First live Slack/Fathom run: three real bugs (user's diagnostic bundle)
- **Unbounded first sync**: no cursor meant "everything" — 44,951 messages back to **2014**.
  Now bounded: `initialHistoryDays` (default 30) for Slack; 90d `created_after` fallback for Fathom.
- **No 429 backoff in LiveSlackClient** (the only client without it) → the 15-min cycle re-slammed
  the limit forever. Now honors Retry-After. users.list refreshed at most daily (sync_state row).
- **12,152 phantom sessions**: SlackSessionizer clustered EVERYONE's messages — colleagues chatting
  became the user's "time". Sessions now anchor on `is_self` messages only; others' messages remain
  stored as note context. Retention now also purges `kind='slack'` sessions older than the
  slack_messages window — they are DERIVED data; the "sessions persist" rule protects primary
  capture only. Existing 12k rows self-heal via the same purge.
- **DoctorView refreshed only onAppear** — a granted permission looked "broken" until the window
  was reopened (second support round-trip caused by a UI staleness, not TCC). Now refreshes every 3s.

### Accessibility saga, closed
- After the signed build: grant still "not showing" → evidence chain: fresh snapshot said granted
  after tccutil reset of SEVEN stale entries (one per build variant) + relaunch; DB shows titles
  flowing (29/39 samples titled). macOS accumulates one TCC row per binary variant and the Settings
  toggle doesn't say which variant it binds — surfaced in Doctor via the signature line.

---

## Doctor tips, guided credentials, Google sign-in (2026-07-27)

### Doctor troubleshooting layer is PURE (2026-07-27)
- `StatusSeverity.classify` + `DoctorTips.tip/hint` (TidySurface) are pure functions keyed to the
  EXACT `PermissionInspector` status strings; `DoctorView` only renders them. Chosen because SwiftUI
  is compile-only headlessly — every decision that matters is unit-tested (`DoctorTipsTests`).
- Fixes the severity bug: `stable (…)` code signature rendered ORANGE (old `color(for:)` only
  greened `granted*`). "app not running" and "provisional" are `.neutral` — benign, not warnings.
- Tip prose encodes this session's real support rounds: stale TCC rows (remove with −, don't
  toggle), relaunch-after-grant, ad-hoc → `find-team-id.sh`, org-id-from-the-URL trick, 429 = wait.
- Ingest rows now surface `sync_state.last_error` (written by every engine since Phase 6, read by
  NO view until now) with pattern-matched plain-language hints; ready-but-erroring renders red.
- `Readiness.needsSignIn(String)` case added ahead of the flow wiring (commit C returns it):
  distinct from `missingCredential` because the FIX is a button, not a paste.

### Google sign-in wired end to end (2026-07-27)
- `GoogleAuthenticator` (TidyIngest): PKCE + CSRF state → real loopback receiver → injected browser
  opener → callback parse → **state validated BEFORE the code is touched** (forged state never
  reaches the token endpoint — tested) → exchange → refresh token to Keychain. On a
  no-refresh-token response (previously-consented account) it retries ONCE with `prompt=consent`.
- **The opener has NO default** — that's what keeps TidyIngest AppKit-free at compile time and makes
  the flow end-to-end testable: tests inject an opener that plays the browser by hitting the real
  socket (`GoogleAuthenticatorTests`, incl. happy path / forged state / denied / timeout / consent
  retry). TidySurface supplies `NSWorkspace.shared.open`.
- Readiness ladder for google: kill switch → client_id (config) → client_secret (Keychain) →
  refresh token → ready; missing refresh token = `.needsSignIn` (a BUTTON, not a paste).
  `run(.googleCalendar)` wires provider+client+CalendarSync with a −30d/+60d first-sync window
  (future events feed nudge suppression); on `refreshRejected` the token is DELETED so readiness
  flips back to `.needsSignIn` instead of a permanently red row (tested).
- `AppEnvironment.signInWithGoogle()` + `googleSignIn` published state; `.failed` sticks until the
  next attempt (an error should not evaporate unread, unlike a transient save note).

### Guided Credentials tab (2026-07-27)
- `CredentialCatalog` (TidySurface): per-key display name, purpose line, ordered plain-language
  steps, help links, and a `pastable` flag. Prose simplified from docs/permissions-setup.md §6–10 —
  BOTH must change together (stated convention; a test can't diff markdown).
- **Lock-once-set is the picker**, not a Keychain restriction: `pickerChoices(present:)` filters
  stored keys out of the add form, so overwriting requires an explicit Remove first. UI-only by
  design — `SecretStore.set` stays callable so `GoogleAuthenticator` and token rotation keep
  writing programmatically.
- `google.refresh_token` is `pastable: false` — it never appears as a paste target (it was in the
  picker before, inviting users to hand-type flow output). Its row's Remove is "Sign out".
- Removal drives a `.confirmationDialog` (destructive role) — first confirmation UI in the app.
- Fixed: `entryKey` was hardcoded to `productive.token` and broke as soon as that key was set; it
  now initializes to the first open picker choice and advances after each save
  (`nextSelection(afterSaving:present:)`, tested).
- Tests pin catalog completeness against `SecretKey.all` (an 8th key without metadata fails CI),
  no-raw-dotted-keys-in-prose, and the lock/unlock picker rules.

---

## Round-3 review fixes (2026-07-27)

### The findings worth remembering (14 fixed; full ledger in PROJECT-REVIEW.md round 3)
- **Concurrent ingest runs were possible** (timer + Sync now + post-sign-in kick, no guard) and a
  Slack first sync can outlive the 900s timer → interleaved delete+rebuild = duplicate sessions.
  Fix: `ingestInFlight` guard in AppEnvironment. The refresh-token delete/rotation race (R1-C4)
  disappears with serialization.
- **Slack names stored during the users.list throttle were permanently nil** — the cursor never
  re-fetches those messages. Fix: `backfillSlackUserNames` UPDATE after each refresh (never
  overwrites an existing name).
- **The menu-bar icon never updated after launch**: MenuBarExtra's label observes AppLauncher, but
  the symbol derives from env.status and nothing forwarded env.objectWillChange. Fix: Combine sink.
- **Redaction had two real holes found by my own new test**: (1) the failure path DELETES the
  rejected refresh token before the catch computed the redaction list → the deleted value wasn't
  redacted from an error echoing it — snapshot `known` BEFORE running each source; (2) a degenerate
  short secret ("s") replaced every letter s in the message — `Redactor.minimumSecretLength = 6`.
- **Google 410 GONE** (expired syncToken) now clears the cursor and re-fetches instead of failing
  identically forever. **Loopback receiver** now accepts in a loop, skipping browser preconnect
  sockets that carry no data (they aborted the whole sign-in). **make-dmg enforces** a non-ad-hoc
  result on the signed path (was display-only). **notificationStatus** cached (15s TTL) — it blocks
  up to 2s and Doctor polls on the main thread every 3s.
- Coverage debt paid: the three first-live-run fixes (Slack 429 backoff, users.list throttle,
  Fathom 90d bound) and the google happy-path sync now have tests. 268 → 279.

### Closure markers (2026-07-27, round-3 R4-8)
- The earlier "**BLOCKER**: xcodebuild is broken on this machine" entry is RESOLVED — a plain
  `xcodebuild -runFirstLaunch` (no sudo) repaired the plug-in cache; the app has built, packaged,
  and shipped signed dmgs since (`9b1915f` onward).
- The "app shell is a Phase-0 placeholder" claims in early entries are superseded by `b5db65a`
  (full surface wired) and the first real run (2026-07-25).

---

## Live-install defect sweep (2026-08-28)

A real install was debugged against `build/v1` @ `8dda588`. Entries below are in the order the work
was done. The first one is the reason the rest were hard to diagnose.

### 0. Build provenance — and what the "stale binary" actually was

**The reported premise was right; the stated cause was wrong, and the difference matters.**

The running app logged `ingest skipped … reason: "not implemented — OAuth sign-in flow not built"`
for `google_calendar` — a string that exists nowhere at HEAD (`IngestCoordinator.readiness`
returns `.needsSignIn` / `.missingConfig` for that source since `1e3ffba`). The conclusion drawn
was "the dmg predates `1e3ffba`, rebuild and reinstall". Rebuilding would have changed nothing.

What was actually true, established by probing every TidyTime binary on the machine for that string:

| Binary | Built | Has the stale string |
|---|---|---|
| `/Applications/TidyTime.app` | 2026-07-27 08:54 | **no** — it is HEAD |
| `dist/TidyTime.dmg` | 2026-07-27 08:54 | **no** — it is HEAD |
| `.build/dd-signed/…` | 2026-07-26 00:13 | yes |
| **`~/.Trash/TidyTime.app`** | **signed 2026-07-27 00:13:02** | **yes** |

`sfltool dumpbtm` showed **two** enabled login items for TidyTime: `2.com.4site.TidyTime` →
`/Applications/TidyTime.app`, and a leftover `2.TidyTime` → `file:///Users/4Site/.Trash/TidyTime.app/`.
The Trash copy is what had been running since `2026-08-11T04:23:14Z` (the last `environment ready`
line). The install was never stale — **a deleted copy was still being launched at login.**

Its commit was pinned by string probe, not by timestamp: the Trash binary contains
`DELETE FROM sessions WHERE kind = 'slack' AND started_at < ?`, introduced by `43ca776`. So the
running build **included** `43ca776` (bounded first syncs, Slack backoff, Fathom 90-day fallback)
and only predated `1e3ffba`. That single fact rules out "the rebuild will fix it" for the Fathom
and Slack items below, which is why it was worth pinning precisely rather than inferring from mtime.

**Decision: provenance is recorded in three places, because each answers a question the others can't.**

1. **`Info.plist` (`TTGitSHA` / `TTBuildTimestamp`)**, substituted from the `TT_GIT_SHA` /
   `TT_BUILD_TIMESTAMP` build settings that `Makefile` and `scripts/make-dmg.sh` pass to
   `xcodebuild`; `project.yml` defaults both to `unknown`. Read back by `BuildInfo.current()`.
2. **`app_metadata.last_run_build` + `last_run_bundle_path`**, written on every launch. This is the
   one that would have ended today's confusion in a single query: it names the *path* of the bundle
   that last opened the database. `tidytime-doctor` is a different binary with its own provenance,
   so it reads these from the DB rather than reporting itself — `DiagnosticsAssembler.extras`.
3. **The `environment ready` log line**, which now carries `git_sha`, `built_at`, `bundle_path`.

**Rejected:**
- *A generated Swift source file with the SHA.* Committing a file that changes on every build is
  churn; not committing it breaks plain `swift test`.
- *Reporting the CLI's own build in the Environment section.* It answers the wrong question. The
  CLI now says `n/a — see last_run_build under Extras` instead, and points at the real answer.
- *Failing the build without a SHA.* `swift test`, `swift run`, and bare Xcode builds are all
  legitimate. They report `unknown`, and the bundle prints an explicit ⚠️ line saying provenance
  could not be established — silence would read as "fine".

A `-dirty` suffix marks a build made from an unclean tree: `8dda588` with uncommitted edits is a
lie, and this whole entry exists because a build misrepresented itself.

### 1. The app now writes `config.json` on first launch

Confirmed exactly as reported: `AppPaths.ensureDirectories()` created the support and logs
directories, and **nothing in the tree ever wrote `configURL`** — all six references were readers
or path-printers. A fresh install ran wholly on compiled defaults, with
`organization.productive_organization_id == ""` → `IngestCoordinator.readiness(.productive)` =
`.missingConfig` → Productive skipped forever. That is why all five `pd_*` tables had 0 rows,
logged 2,259 times as `ingest skipped … config organization.productive_organization_id is unset`.
Not a stale-build artifact: those three files are byte-identical between the Trash build and HEAD.

**Seeding lives in a new `ConfigSeeder`, not in `ensureDirectories()`.** That function's contract
is filesystem *layout*; file *content* is policy. The `tidytime-doctor` CLI resolves the same paths
and is written specifically to avoid mutating the support directory — folding a write into a path
resolver would make it do so as a side effect, and every test that calls `ensureDirectories` on a
temp dir would silently acquire a config file.

**The seed is a subset of `config.example.json`, not a copy.** Absent blocks and absent fields both
fall back to compiled defaults, so omitting is safe and writing is a commitment. Seeded:
`organization` (org id, person id, timezone) and `google` (client_id, internal_domains) — the keys
a user must actually set — plus `_about`/`_help` prose, since JSON has no comments and unknown keys
are ignored by the decoder. Omitted and why:

- **The whole `ai` block.** Unconfigured, `AIRouter` returns `.failed("no route for job")` and
  sends nothing — a clean state. The example would replace it with model slugs its own
  `_build_time_checks` flags as unconfirmed, plus a **null-priced** Claude entry that `ModelCost`
  values at `$0` — silently disabling that model's G5 daily cap. A budget cap that reads zero spend
  is worse than no cap, because it looks like it is working.
- **Every `REPLACE_WITH_…` placeholder.** `google.client_id` is the sharpest: it is the one
  placeholder with no guard, and a non-empty value defeats the `.isEmpty` checks in both
  `IngestCoordinator` and `signInWithGoogle`, trading a precise "add your Client ID" tip for an
  opaque OAuth error against a bogus client.
- **`productive`.** Its `task_deep_link_pattern` was wrong on both the org token and the path (see
  item 2). Seeding a plausible-looking broken URL is worse than leaving the default.
- **`capture`, `sessionization`, `suggestions`, `recap`, `nudges`, `retention_days`, `ingest`.**
  All equal their compiled defaults; seeding them freezes today's numbers into every install where
  a future default improvement can never reach them.

**No-overwrite is absolute** — existence is the only test, and the file's contents are never read.
The machine this was found on is the argument: its `config.json` had been hand-written hours
earlier with a real org id and a corrected deep-link pattern. An overwriting *or merging* seeder
destroys that. An empty or corrupt file is still a file and is likewise left alone; replacing it
would destroy the evidence of the parse error the user is trying to fix. Failure to write is
reported and logged, never fatal — a read-only support directory must not stop the app.

**Doc bug found while fixing this:** README.md and RUNNING.md both said
`cp config.example.json config.json`, which puts the file in the **repo root**. The app reads
`~/Library/Application Support/TidyTime/config.json`. That instruction has never had any effect on
a running app. Both now point at the real path and say the app creates it.

#### 0a. Follow-up: the provenance stamp could itself lie

Caught by an adversarial review of the item-0 change, before it shipped further. The first form of
the stamp was:

```make
GIT_SHA := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)$(shell git diff --quiet HEAD 2>/dev/null || echo -dirty)
```

Outside a git repo — an exported tarball, a `.git`-less copy — `rev-parse` fails to `unknown` and
`git diff` *also* fails, appending `-dirty`. Result: `unknown-dirty`, which is not equal to
`"unknown"`, so `isProvenanceKnown` returned **true** and the bundle suppressed its own
"⚠️ carries no git SHA" warning while printing `Git SHA: unknown-dirty` as though it were real.

A feature built to stop a build from misrepresenting itself, misrepresenting itself. Fixed on both
sides: the shell now appends `-dirty` only when a SHA was actually obtained, and
`isProvenanceKnown` matches on the `unknown` **prefix** rather than equality, so any future
decoration of the fallback still fails closed. Pinned by test.

Also removed: `DiagnosticsAssembler.extras(db:build:logURL:)` never read its `build:` argument —
dead API that implied the caller's own provenance fed Extras, when the entire point of that
function is that it does **not** (it reads `last_run_*` from the database instead).

### 3. Slack — one unreachable channel took down the whole source

`SlackSync.run()` iterated conversations in a bare `for` loop with no per-conversation error
boundary. `try await client.history(...)` was the abort: `channel_not_found` on `C07C12FMTEF`
unwound the entire loop, so every conversation ordered after it was skipped and
`IngestCoordinator` recorded the whole source as failed. The live DB shows the shape exactly —
120 per-conversation `slack:<id>` rows all stamped `18:44:13`, the top-level `slack` row stamped
`18:52:28` with the error, and **`last_success_at` NULL**: one 8m15s pass that synced 120
conversations and then threw. Slack had never once completed a run, despite 7,309 banked messages.

Not a stale-build artifact — the loop has been unguarded since the original Slack ingest commit;
neither `43ca776` nor `30406ad` touched it.

**The enabling defect was the error type, not the loop.** `checkOK` collapsed every `ok:false`
body into `IngestError.transport("slack error: \(code)")`, so `channel_not_found` (skip),
`ratelimited` (back off) and `invalid_auth` (stop) were indistinguishable at every catch site —
skip-vs-retry-vs-abort was structurally impossible. Fixed first: `IngestError.slack(code:method:)`
carries the code as a field. `description` still renders `transport error: slack error: <code>` so
existing Doctor hints and log scraping keep matching. `method` is carried because the same code
means different things per method.

**Answering the question that was asked — `channel_not_found` is not sufficient.** Verified against
Slack's live method references on 2026-08-28:

- `not_in_channel` is documented on `conversations.history` as "the token does not have access to
  the proper channel" — membership for *this* channel, not authorization in general.
- Archiving a **public** channel drops its membership roster, so history then returns
  `not_in_channel`, **not** `is_archived` — and `conversations.join` cannot recover because *that*
  returns `is_archived`. Permanently unreachable via a code that never mentions archiving.
- `is_archived` is documented only on **mutating** methods; Slack blocks writes to archived
  channels and permits reads. Handled anyway — cheap, and the split is not guaranteed to hold.
- Which code a **left private channel** returns is documented nowhere. Treat `channel_not_found`
  and `not_in_channel` as interchangeable outcomes of the same real-world event.
- `conversation_not_found` **does not exist** in Slack's API. A test pins that we never add a
  branch for it.

Unknown codes classify as **fatal**, not skippable — fail closed. Silently skipping conversations
on an unrecognized error is how a sync goes quietly and permanently empty. `ratelimited` is
explicitly *not* a skip: skipping would drop real messages and leave the cursor wrong, and Slack
meters per method per workspace per app, so a 429 on one channel predicts one on the next.

**Persistence with a cooldown, not a tombstone.** The unreachable marker goes in
`sync_state.last_error` on the existing `slack:<conv>` row — no migration, and it survives restarts,
which an in-memory set could not (`IngestCoordinator` builds a fresh `SlackSync` every pass).
Re-probed after 24h rather than skipped forever, because Slack documents that conversation IDs are
**not stable** (a shared private channel can flip `G…` → `C…`), so a stored id can return
`channel_not_found` for a channel that still exists; and a rejoined channel should heal without the
user knowing this state exists. 96 pointless requests a day become one. A successful pass clears the
marker.

"Log once" falls out of the persistence: the info line is emitted only on the transition into
unreachable, so it appears once per outage rather than every fifteen minutes.

**Deliberately NOT changed:** `conversations.list` still omits `exclude_archived=true`, which
`docs/reference/slack-api.md` prescribes and the code has never done. Adding it would change *what
data is collected* — archived channels still have readable history and represent real past work —
and that is a scope call for the owner, not a side effect of a crash fix. The per-conversation skip
makes the noise harmless either way. Recorded here so the divergence is not lost.

Also corrected in `docs/reference/slack-api.md` while verifying: the "Sept 2, 2025 → Mar 3, 2026"
existing-install phase-in dates appear on **no** live Slack page (the May 2025 changelog, the June
2025 clarification, the rate-limits guide, both method pages, the changelog index and the 2026
recaps were all checked) and the live banner says the opposite. Removed as unsourced. Open item
**B3 resolved favorably**: internal customer-built apps remain explicitly exempt, so the poll-only
design holds.

### 4. Fathom — the 429 loop was structural, and the rebuild does **not** fix it

**Direct answer to the question asked: no.** `FathomClient.swift` and `HTTP.swift` are
**byte-identical** between `43ca776` (in the running Trash build) and HEAD `8dda588`.
`git log --follow` on FathomClient.swift returns exactly two commits ever — `7a6d914` (created it,
including `sendWithRetry` and `maxRetries: 3`) and `43ca776` (added only the 90-day fallback).
Installing the current build reproduces this defect exactly.

Empirically confirmed rather than inferred: the `43ca776` binary was signed 2026-07-27 04:13:02Z;
the log holds 55 Fathom 429s before that instant and **2,191 after it**, uninterrupted through
2026-08-28. `last_success_at` was never set — Fathom has never once succeeded.

**Root cause: all-or-nothing pagination plus cursor-only-on-success.** `fetchMeetings` accumulated
up to 100 pages into an array and returned only after the whole walk; `FathomSync.run` persisted
nothing until that call returned, and wrote the cursor after that. So a 429 on *any* page threw out
of the accumulator, **discarded every page already fetched and parsed**, and left the cursor
untouched. 900s later the run recomputed `now − 90 days` and replayed the identical page sequence
into the identical limit. A closed loop with no exit and no forward progress.

The log caught it in the act: 6 of the 12 leaked request URLs carry `&cursor=eyJob3N0X2NhbGxz…`,
proving the run had reached page 2+ before dying — and those pages went in the bin.

**The 90-day bound could not have helped.** It shrank the input; the failure is structural, not
size-dependent. Its own comment ("an unbounded first pull 429-loops forever") diagnosed the symptom
correctly but the fix addressed only input size, not the discard-everything control flow.

Fixed by inverting who drives pagination: `fetchMeetingsPage(createdAfter:cursor:)` returns one
page, `FathomSync.run` loops, and **each page is persisted and the cursor advanced before the next
request is made.** A rate limit becomes a pause instead of a wall. `lastSuccessAt` is stamped only
on a complete walk, so a partial run is not misreported as clean.

**Three contributing defects fixed with it:**

1. **The retry budget was ~17× too small.** `maxRetries: 3` with `Backoff(base: 0.5, cap: 30)`
   sleeps 0.5 + 1 + 2 = **3.5 seconds total** against a rolling **60-second** window. Measured run
   duration (median 12s over 2,259 runs) matches that exactly. `docs/reference/fathom-api.md`
   already prescribed "start at ~5s and double" — the code just didn't. Now base 5, 5 retries:
   5+10+20+30+30 = 95s, which clears a 60s window with margin.

2. **`Retry-After` handling was dead code, in all three clients.** Two independent reasons.
   (a) Fathom sends **no `Retry-After` at all** — a live probe returns the IETF family
   `ratelimit-limit: 60`, `ratelimit-remaining: 0`, `ratelimit-reset: 0`. (b) HTTP/2 lowercases
   header names on the wire, and `URLSessionHTTPClient` copies them into a **case-sensitive**
   dictionary that all three clients then subscripted with the literal `"Retry-After"`. So every
   server-directed backoff was silently ignored in production while the code looked correct —
   including Slack's, whose comment claims "Honors Retry-After, which Slack always sends on 429".
   Fixed centrally: `HTTPResponse.serverRequestedDelay` looks up case-insensitively and falls back
   to `RateLimit-Reset`. This one is a cross-client fix; it lands here because Fathom is where it
   was caught.

3. **`http 429: ` with an empty body was unactionable** — logged 2,246 times over 33 days without
   once saying what was tried or what to check. `IngestError.rateLimited` now states the attempt
   count, the real waited time, Fathom's actual heavy-call limits, that partial progress was kept,
   and where to check the key.

**A note on rate-limit arithmetic, because it shaped the diagnosis.** A 60-second window cannot
stay exhausted across a 15-minute cadence — even the 5/60s floor resets 14 minutes before the next
run. So "days of continuous 429s" was never a limits problem to tune away; it had to be a run
re-requesting the same pages every time. That reasoning is what pointed at the discard-and-replay
loop rather than at the backoff, and it is recorded in `docs/reference/fathom-api.md` so the next
person does not "fix" this by lengthening a sleep.

Rate limits themselves re-verified against Fathom's live docs and **unchanged**: 60/60s standard,
30/60s heavy, floor 5/60s. The `⚠️ Build-time check` on whether a 429 carries `Retry-After` is now
resolved (it does not). Open item **A1 resolved**: API access is confirmed working — the key exists
and the endpoint answers. Worth stating plainly that A1 being green never implied ingest was
working; `meetings` sat at 0 for 33 days with a perfectly good key.

### 5a. `page_snapshots` = 0 — environmental cause, but a real code defect underneath

**The cause is the one that was guessed: Chrome's "Allow JavaScript from Apple Events" is off.**
Proved, not assumed. Chrome persists it as `allow_javascript_apple_events` (string extracted from
the installed Chrome Framework binary); Chromium writes only non-default pref values, and the key
is absent from Local State and from **all** profile `Preferences`/`Secure Preferences` files — so it
has never been enabled in any profile.

Two independent confirmations of the mechanism:
- `activity_samples` holds 34,586 Chrome rows **with URLs**. The URL/title path (`activeTab()`)
  uses plain scripting terms and needs only Automation; page text needs `execute javascript`, which
  the toggle gates. Automation is clearly granted. That split is the signature.
- `sqlite_sequence` has rows for `activity_samples`, `sessions` and `slack_messages` but **none for
  `page_snapshots`**. SQLite creates that row on the first successful insert into an AUTOINCREMENT
  table and never removes it on DELETE — so the table has never had a single successful insert in
  the database's entire life. That rules out retention having eaten the rows, without argument.

Everything else was ruled out with evidence: no code gate (every capture default is permissive and
`killSwitches.chrome` is never even read); the content tick fires (the detection tick provably does,
they are scheduled together, and `poll()` also force-fires content on every page change);
`git diff 43ca776..HEAD -- Sources/TidyCapture` is empty, so it is not stale-build-only.

**But "setup-doc gap, not a code bug" is the wrong call, and I'm disagreeing with the brief here
deliberately.** The instruction was to handle it as a doc gap if it turned out to be the toggle. It
is the toggle — and there is no doc to write. `docs/permissions-setup.md` §3 already documents the
exact View → Developer click-path, correctly, and has all along. The gap is on the other side:

- That same section tells the user to **verify** with `make doctor` → Chrome JS = `ok`, and the
  final acceptance table lists the row. **No such row existed.** `PermissionInspector.statuses()`
  never emitted it and `DiagnosticsAssembler`'s allow-list never parsed it. A documented
  verification step the user was structurally unable to perform.
- Phase 1's acceptance criteria require "…`page_snapshots` gains no rows, **and `doctor` reports the
  degraded state**" and "degrades silently to URL+title on any failure **and surfaces the state in
  `doctor`**". Two thirds shipped; the reporting clause never did. A failing acceptance criterion is
  a code defect, not a documentation one.

So: the user's action is still to flip the Chrome toggle — that is the only way rows will ever
appear — but the code owed a way to *find that out*. Shipped:

- A `Chrome JavaScript (Apple Events)` Doctor row, driven by the existing (previously caller-less)
  `javaScriptFromAppleEventsEnabled()` probe, now classified into distinct outcomes: `ok`,
  toggle-off, automation-denied, not-determined, Chrome-not-running. The classifier is a pure
  function in `TidyCapture` so it is unit-testable without AppleScript. Cached at 15s like
  `notificationStatus` — Doctor refreshes every 3s and a synchronous AppleScript round-trip on the
  main thread must not run at that rate.
- The key added to `DiagnosticsAssembler`'s `known` list, so it survives the render → parse
  round-trip the `tidytime-doctor` CLI performs (pinned by test — a key missing there is silently
  dropped).
- A troubleshooting tip with the literal click-path, which also tells the user this is a Chrome
  setting and **not** something to hunt for in System Settings. When Automation is the real blocker,
  the tip points at that row instead of sending the user to flip a toggle that would not help.
- `document.body.innerText` → `document.body ? document.body.innerText : ''`. The bare form throws
  on `chrome://`, the PDF viewer and blank tabs, and a thrown script was indistinguishable from the
  toggle being off — those pages were poisoning the diagnosis.
- `PermissionInspector` no longer hard-crashes outside an app bundle.
  `UNUserNotificationCenter.current()` raises an **uncatchable** ObjC exception when the process has
  no `.app` bundle; the guard is on the bundle shape, not its identifier, because a test runner
  reports an identifier while its `bundleURL` is a plain directory. An inspector that crashes
  outside an app bundle is unusable by exactly the tooling that most needs it.

`grep jsEnabled Tests/` previously matched nothing — the fake adapter modelled this failure exactly
and no test used it. It does now.

### 5b. `daily_rollups` = 0 — the job was never invoked

`RecapAssembler.writeRollup` is the **only** writer of `daily_rollups`, and its only callers in the
entire tree were three unit tests. Zero call sites in `App/` or any `Sources/` target.
`AppEnvironment.runPipelineOnce()` — the 300s batch pass — did exactly four things: rebuild
sessions, classify the day, refresh the recap, purge retention. No rollup.

So the context-switching metrics from `bf5463f` computed correctly and were persisted by nobody.
The table sat at 0 while 3,669 sessions accumulated. Nothing surfaced it, because **a job that is
never invoked cannot log a failure** — there is no error, no `sync_state` row, no Doctor line. The
tests passed because they called the method directly, which is precisely how the gap survived.

Fixed with one call site in `runPipelineOnce()`, plus one thing that is not obvious: **yesterday is
re-rolled alongside today.** The timer only ever knows about the current day, so without it
yesterday's row is frozen at whatever the last pre-midnight pass computed and permanently loses its
final minutes. `upsertRollup` keys on the day, so re-rolling is idempotent — pinned by a test that
runs four passes and asserts exactly two rows.

### 6. Documentation corrections — one of which pointed at the wrong file

**6.1 — Step 6.3 told the user to paste the organization id into a field that does not exist.**
Confirmed: `SettingsView` has three tabs; General is a read-only dump built from `Text` labels with
zero editable controls (its own header even reads "Config is a plain JSON file you can edit
directly"), and Credentials writes **only** to the Keychain via `secrets.set`. No code path in
`SettingsView` writes `config.json` at all. `CredentialCatalog` and `TroubleshootingTips` already
said the right thing; only the markdown was wrong. Now split into two steps — token → Settings →
Credentials, org id → `config.json` — and it says explicitly that there is no Settings field, so a
reader who goes looking stops looking.

**6.2 — The §0 lead-in contradicted its own table.** It introduced the account names as "the
**suggested convention** (confirm against the `SecretStore` keys the app actually reads)" while the
table header two lines below said "**exact**, must match `SecretKey`" and the paragraph below it
said "the account names above are exact". `284dc52` rewrote the table and added that paragraph but
left the lead-in as untouched context. Replaced with an unambiguous statement, stamped with the
verification date.

**6.3 — The report was half right, and pointed at the wrong file.** The claim was that
`permissions-setup.md` lists `fireworks_api_key` / `anthropic_api_key` with underscores. It does
not — **that table has been correct since `284dc52`**: lines 52–53 are `fireworks.api_key` and
`anthropic.api_key`, dotted, and the table matches `SecretKey.all` completely (all seven, including
`google.client_secret` added later by `f076d4d`). The surviving underscored names were in
`docs/open-items.md`, inside **B8's own "why it matters" bullet** — `284dc52`'s open-items hunk
rewrote only the first line of that wrapped bullet and never touched the continuation line carrying
the last two names. A doc describing a naming bug, still containing the bug. Fixed there.

Open item **B8 resolved**, with the canonical list written into it: seven `SecretKey` constants
under service `com.4site.TidyTime`. Worth recording that `google.client_id` is deliberately **not**
among them — it is non-secret and lives in `config.json`. I got that wrong in a first draft of the
resolution text and caught it by reading `SecretKey.all` rather than trusting the surrounding prose,
which is the same failure mode this item is about.

**Found but NOT fixed — `make lint` is red at HEAD.** `scripts/check-doc-links.sh` reports **26
broken links** and exits 1. Every one points into `docs/build/` (`signing-and-tcc.md`,
`testing-strategy.md`, `environment-setup.md`, `xcodegen-spec.md`) — a directory that does not exist
in the tree. This is pre-existing at `8dda588`, is unrelated to every item in this sweep, and none
of my edits added to the count (verified: 26 before, 26 after). Fixing it means either writing four
missing docs or rewriting links across a dozen files — a scope call for the owner, not something to
fold silently into a defect sweep. Flagged rather than fixed.

---

## Second live sweep (2026-08-28, after installing 22eb749)

### 0. What the first sweep's fixes actually did in production

Recorded because it is the evidence, and because the picture changed under me mid-session.

Installing `22eb749` moved every needle the first sweep aimed at:

| Table | Before | After 22eb749 ran |
|---|---|---|
| `meetings` | 0 | **201** |
| `transcript_utterances` | 0 | **61,479** |
| `daily_rollups` | 0 | **2** |
| `page_snapshots` | 0 | **30** |
| `pd_companies` / `pd_projects` / `pd_people` | 0 | 687 / 965 / 1,878 |
| `pd_tasks` / `pd_time_entries` | 0 | **0** ← item 2 below |

`ingest ok fathom` at 20:45:43 and `ingest ok slack` at 20:55:04 — both firsts. The Fathom cursor
advanced to `2026-08-28T16:58:05Z` with `last_success_at` set, so the per-page persistence fix did
what it was designed to do. Slack logged
`slack conversation unreachable — skipping it, syncing the rest` exactly **once** and completed.

**Two corrections to the first sweep, both from ground truth:**

1. **The unreachable conversation is `D051S3F9W`, not `C07C12FMTEF`.** The live marker row reads
   `unreachable-since:1787949943 channel_not_found (conversations.history)` for `D051S3F9W` — a
   **DM** (`D` prefix), not a channel. `C07C12FMTEF` synced *successfully* at 20:45:43. The original
   attribution was an inference: the error line carries no conversation id. The archived-public-
   channel theory was therefore not what happened here; a DM with a deactivated user is likelier.
   The fix was still correct and still worked — it skipped the right conversation.

2. **"`last_success_at` NULL proves Slack never succeeded" was not sound reasoning.**
   `IngestCoordinator` writes `sync_state` **only in its catch block**; the success path never
   stamps the top-level row. Fathom and Google write their own, Slack does not — so `slack`'s row
   can only ever contain errors. The defect was real and independently proven (the loop had no error
   boundary, by inspection), but that particular piece of evidence did not support it. Noted so the
   next reader does not repeat the inference. *(A source that succeeds should record it; not fixed
   here, out of scope.)*

**And a build regression caught by the provenance feature, within minutes of it shipping.** At
20:56:26 `/Applications/TidyTime.app` was replaced with a **pre-provenance build** (no `TTGitSHA`,
no `unreachable-since:`, no `rate limit: still refused`), which launched at 20:57:30 and is what is
running now. Its `environment ready` line carries only `{"db":…}` — the old field set — sitting 25
seconds after a line that carried the full provenance. The symptoms returned immediately: `http 429:`
in the old wording at 20:57:45, `channel_not_found` aborting the run at 21:07:07. The likely cause is
opening the *main repo's* `dist/TidyTime.dmg` (Jul 27, = `8dda588`, predating all nine commits)
rather than the worktree's. This is precisely the confusion item 0 of the first sweep existed to
make visible, and it took one `PlistBuddy` read instead of a day.

### 2. Productive `task_number` — a type mismatch that cost two whole tables

`ProductiveClient.TaskAttrs.taskNumber` was `Int?`. The live API sends `task_number` as a
**string**. First live task sync:

```
decoding error: tasks: DecodingError.typeMismatch: expected value of type Int.
Path: data[0].attributes.task_number. Expected to decode Int but found a string instead.
```

The blast radius is the point. `ProductiveSync.run()` fetches tasks *before* time entries, so the
throw aborted the function and **neither** ran — `pd_tasks` and `pd_time_entries` both zero while
companies, projects and people synced normally. It also silently disabled gap analysis, which needs
`pd_time_entries` to know what was already logged.

**Why the 332-test suite said nothing.** `docs/reference/productive-api.md` showed `"task_number": 412`, an
integer. The model was written from the doc and the fixtures were written from the doc. All three
agreed with each other and disagreed with Productive. A fixture that encodes our assumptions cannot
falsify them.

**A second one was hiding behind the first.** `status` was `String?` while the doc's own fixture
shows `1`. Swift decodes in property order, so the throw on `taskNumber` meant `status` was never
reached — fixing only the first would have surfaced the second on the very next sync.

**Fixed structurally, not by flipping types**, per the same principle as the Slack conversation skip:

- `KeyedDecodingContainer.lenientInt` / `.lenientString` accept a JSON number *or* a JSON string and
  **never throw**; an unparseable value degrades that one field to `nil`.
- Applied to **every** numeric-ish attribute, not just the two known-bad ones. `company_type_id`,
  `project_type_id` and `number` are the same risk class and have never been checked against live
  data; they are lenient on that basis rather than waiting to be surprised.
- `JSONAPIDocument` now decodes `data` **element by element**, keeping good resources and counting
  bad ones in `skipped`. One malformed resource costs one row, not the source.
- `time` on a time entry stays **required** — a duration is the load-bearing value and a made-up `0`
  would silently corrupt logged minutes. It is lenient about representation only; a genuinely
  unusable one drops that row via the element skip.
- Skips are logged at **error** level with the path and kept/skipped counts. A mirror that quietly
  shrinks is worse than one that complains.

No migration: the column stays `.integer` and `PDTask.taskNumber` stays `Int?`.

**A hazard the element-skip introduced, and the guard for it.** Pagination decided "last page" by
`doc.data.count < pageSize`. With skipping, a page whose rows all failed would look short and end
the walk early, silently truncating the mirror. Fullness is now judged on **resources received**
(`data.count + skipped`), pinned by `testPageFullnessCountsSkippedResources`.

**Rejected:** changing `taskNumber` to `String?`. It is a number, the DB column is `.integer`, and
`PDTask.taskNumber` is `Int?` — pushing the string outward would force a migration and move the
parsing problem into the store instead of solving it at the boundary where the vendor's ambiguity
actually lives.

**The fixture is the deliverable.** `ProductiveIngestTests.tasks` now carries `"task_number":"101"`
and `"status":1` — the live shapes, inverted from the doc on both fields. Verified by reverting the
model to a strict `Int` decode with the new fixture in place: `ProductiveIngestTests` drops to zero
passing and `testLiveTaskShapeDecodes` fails. The fixture now falsifies the bug it used to hide.

### 4. Papercuts from live use

All four real, all small, all confirmed against the code before changing anything. One report was
wrong about the mechanism, which changed the fix.

**`Sync now` looked broken.** The report attributed this to `counts`/`lastErrors` being loaded by
`.onAppear` only. **Not accurate** — `DoctorView` already reloads on a 3s timer (added in round 3,
so a fresh TCC grant shows without reopening the window). The observed symptom is real but the
cause is different: a sync takes seconds to minutes, and the button gave **no in-progress state at
all**, so the first visible change arrived long after the click. Fixed with what already existed:
`AppEnvironment.ingestInFlight` is `@Published`, so the button now reads "Syncing…", disables
itself, shows a spinner, and stamps a completion time on the falling edge — plus an immediate
`reload()` there so counts update on completion rather than up to 3s later. No redundant refresh
was added.

**A row could read "ready" in red.** `ingestColor` returns red for a runnable source whose last sync
errored, while the label still said "ready" — colour said broken, word said fine, and the reason sat
collapsed behind "How to fix". The failure is now in the row:
`ready — last sync failed: <first clause>`, via a pure `DoctorTips.ingestLabel` so it is unit-tested
rather than eyeballed. The row is trimmed to one line (the new Fathom rate-limit message is a
paragraph); the tip below still carries the untrimmed error, pinned by test.

**Tips named a button without saying where it is.** Both call sites now say it is at the bottom of
the Sources list in Doctor **and** that the menu bar popover has no sync button — the popover is
where a person naturally looks first.

**`make test` ended on a line that reads as zero tests.** The suite is entirely XCTest, but
swift-testing still runs and prints `Test run with 0 tests in 0 suites passed` **last**, after the
real total has scrolled by. A human reads the final line and concludes nothing ran. `make test` now
re-states the XCTest summary as the last line, and preserves the exit status through the pipe with
`set -o pipefail` so a failure still fails the target.

### 2a. A second blocker behind the decode fix — Productive never knew who "you" are

Found while doing the live verification item 2 asked for. Fixing the decode was necessary and not
sufficient: `pd_time_entries` would have stayed at zero regardless.

`ProductiveSync.run()` computes `effectiveAssignee = assigneeId ?? selfId`, where
`selfId = db.resolveSelf(email: selfEmail)`. But `IngestCoordinator` constructed
`ProductiveSync(client:db:clock:)` — **without `selfEmail`**, which defaults to `nil`. And
`organization.productive_person_id` was unset on this machine. So both inputs were nil, with two
consequences that both present as "sync is broken":

1. `fetchTasks(assigneeId: nil)` fetches **every task in the organization** rather than the user's —
   up to the 100-page × 200 safety valve, 20,000 tasks. Observed live: the run went quiet for
   minutes at 0.1% CPU with nothing written, because `fetchAll` accumulates every page before
   `upsertTasks` sees any of it. Same all-or-nothing shape as the Fathom bug, on a different source.
2. Time entries are gated on `if let personId = selfId ?? assigneeId` — with both nil the fetch is
   **skipped entirely, silently**. No error, no log line, no `sync_state` row. `pd_time_entries`
   could never have been non-zero no matter how well tasks decoded.

The report attributed both empty tables solely to the decode abort. That is exactly right for
`pd_tasks`, and right as the *first* blocker for `pd_time_entries` — but a second one sat behind it,
which is the third time this session that pattern has appeared (`status` behind `task_number`,
this behind the decode).

**Fix:** added `organization.productive_self_email` and wired it through, so `resolveSelf` maps the
email to a person id from the already-synced `pd_people` and nobody has to look an internal id up by
hand. It resolves both consequences at once: the task fetch gets filtered to the user, and time
entries start running.

Email rather than reusing `productive_person_id` because the id is not discoverable without already
having synced — a bootstrapping problem the user cannot solve from the UI. On this machine the
people table contains **two** matching rows (`bryan@4sitestudios.com` → 32510 and
`bryan.casler@gmail.com` → 32842), so guessing by name would have picked the wrong account half the
time; the email disambiguates.

An existing config is unaffected: without the new key `selfEmail` is nil, `selfId` is never
assigned, and both call sites collapse to `assigneeId` exactly as before. Note the two
precedences differ **on purpose** — tasks use `assigneeId ?? selfId` (fetch scope, explicit id
wins) while time entries use `selfId ?? assigneeId`, which must match `db.selfPerson()` because
`SuggestionEngine` queries time entries by that id. I unified them and reverted it; see item 2b.

### 2b. Pre-push review — one real regression I introduced, and one "fix" I had to revert

Before pushing to `origin/main` I ran an adversarial review of the four unpushed commits: four
reviewers by dimension, then a refutation pass over every blocker/should-fix. 17 raw findings, 1
confirmed (a nit), most refuted on scope or reachability. Two outcomes were worth the exercise.

**A real regression, caught and fixed: `lenientString` on presence-flag timestamps.**
`closed` is derived as `closedAt != nil` and `archived` as `archivedAt != nil`. `lenientString`
coerces JSON `false` into `"false"` and `0` into `"0"` — both non-nil. Verified with a standalone
decoder probe rather than by argument:

```
{"closed_at":null}   -> nil              closed=false
{"closed_at":false}  -> Optional("false") closed=true   ← every task closed
{"closed_at":0}      -> Optional("0")     closed=true
```

`main` did not have this: strict `decodeIfPresent(String.self)` *throws* on `false`, which aborts
loudly. My change turned a loud abort into silent data corruption — strictly worse. Fixed with
`lenientTimestamp`, which accepts a real non-empty string or nothing and still never throws.

The general lesson, now in the code comment: **leniency is right for a value that is genuinely
number-or-string, and actively wrong for a value whose *presence* is the signal.** I applied the
pattern uniformly instead of asking what each field meant. Pinned by three tests.

**A "fix" I made and then reverted: unifying the assignee precedence.** Tasks use
`assigneeId ?? selfId`; time entries use `selfId ?? assigneeId`. That looked like an obvious
inconsistency and I changed both to the former. The refutation showed why that is a bug:
`db.selfPerson()` reads `pd_people.is_self`, written **only** by `resolveSelf(email:)` — i.e. from
`selfId` — and `SuggestionEngine` then queries `timeEntries(personId: selfPersonId)`. With the two
ids differing, my version would fetch one person's time entries while the rest of the app asked for
another's, yielding silently zero logged time. The asymmetry is deliberate: tasks is a fetch-*scope*
question where an explicit id wins; time entries must agree with downstream identity. Reverted, and
the reasoning is now a comment so the next person doesn't "fix" it either.

Also corrected: the DECISIONS/commit claim "`productive_person_id` still wins when set" was
over-broad — true for tasks, false for time entries. The clause that mattered ("an existing config
is unaffected") was correct, and for a reason worth keeping: without the new key `selfEmail` is nil,
so both expressions collapse to `assigneeId` exactly as before.

**Kept despite being refuted as out-of-scope**, because they are small and real: logging when a
configured `productive_self_email` matches nobody (the refutation itself conceded this is a genuine
diagnostics gap — a set-but-unmatched email is currently indistinguishable from an unset one), and
logging when a fetch hits the 100-page cap and silently truncates. Both are the same "never fail
silently" principle the rest of this sweep is built on.

**The confirmed nit:** the outage narrative said "279 passing tests" in two places and "340" in a
third. The suite that actually missed the `task_number` mismatch was **332** — 347 today minus the
8 tests added in `4b3be64` and the 7 in `ac83156`. 340 was self-defeating, since 8 of those were
written in that very commit *to catch the bug*. Corrected to 332 everywhere. Also caught: `9ef01af`,
whose one job was replacing carried-forward numbers, walked past `site/index.html` — still 279,
now 347.

## Google console navigation renamed; Internal is still the only sane choice (2026-08-28)

Setting up the Google client for the first time surfaced that our click-paths point at menus Google
has since renamed. Corrected in `permissions-setup.md` §9 and in the `CredentialCatalog` steps the
Settings pane renders:

- **OAuth consent screen** is now **Google Auth Platform → Audience**.
- **APIs & Services → Credentials → Create Credentials → OAuth client ID** is now **Google Auth
  Platform → Clients → Create client** (`console.cloud.google.com/auth/clients`).
- Both docs now name the old label too, because every third-party walkthrough still uses it.

Re-verified against Google's live docs while making the change:

- **Desktop app + loopback is safe.** The loopback IP address flow deprecation applies to Android,
  iOS and Chrome app clients only; Google's migration guide states Desktop app clients continue to
  be supported. Our ADR choice of loopback + PKCE for an installed app needs no revisiting.
- **The 7-day trap is real and precisely scoped.** It fires on *external* user type **and**
  publishing status `Testing`, unless the scopes are a subset of name/email/profile.
  `calendar.readonly` is not in that subset. `Internal` remains the requirement.
- **New in the doc:** `External` + `In production` also avoids the 7-day expiry, so a project that
  cannot live in the Workspace org is not a dead end. It is a slow path, because a sensitive scope
  then needs Google's verification. Recorded so nobody rediscovers `External` + `Testing` as the
  apparent workaround.

Not changed: the three-values-three-places table was already correct, including that the client
secret is pasted in **Settings → Credentials** rather than written with the `security` CLI. Writing
it by hand invites exactly the ACL mismatch the 2026-07-25 Keychain entry describes, and it puts the
secret in shell history for no benefit.

---

## Phase 5 completion: making the app actually suggest time entries (2026-08-28)

The app had captured 48,073 samples and 3,890 sessions since late July and produced **zero**
suggestions — the one thing it exists to do. Not one bug but a severed chain, each link verified
against the live database and the live API. Stages below are in dependency order.

### 1. Productive relationships were never requested

**Root cause, and it is one missing query parameter.** Productive omits relationship *linkage*
unless you send `include=`:

```
GET /tasks?page[size]=1                  ->  "project": {"meta": {"included": false}}   ← no data key
GET /tasks?page[size]=1&include=project  ->  "project": {"data": {"type":"projects","id":"16332"}}
```

Our JSON:API parsing was **correct** — `relationshipId` returns nil when there is no `data`, which is
right. We simply never asked. Consequence, measured before the fix:

| Column | Rows | Empty |
|---|---|---|
| `pd_tasks.project_id` | 11,631 | **11,631** |
| `pd_projects.company_id` | 965 | **965** |
| `pd_time_entries.task_id` | 160 | **160** |
| `pd_time_entries.person_id` | 160 | **160** |

The person_id one is the tell: it was empty despite `filter[person_id]` being what fetched those
very rows. A mirror of disconnected tables — 11,631 tasks belonging to nothing — which starves
`Classifier` (it builds task candidates by walking task → project → company, so it built none),
which leaves `sessions.task_id` at 0/3890, which makes `SuggestionEngine` unable to emit anything
but junk. Every downstream symptom traces here.

`docs/reference/productive-api.md` showed `include=` in all three sample requests. The code sent
none. The doc was right and the code was wrong — the reverse of the `task_number` case earlier the
same day, which is a useful reminder that "the doc is stale" is a hypothesis, not a default.

**Rejected:** adding `fields[…]` sparse fieldsets alongside `include`, which the doc's samples also
show. Narrowing the attribute list is precisely how you silently drop a field you already depend on;
the payload saving is not worth reintroducing the `task_number` failure mode. Documented as a
"do not" in the reference.

**Also added:** a loud check for the failure returning. `PDMapper` coerces a missing relationship to
`""`, which is how this hid for a month — an empty foreign key joins to nothing and raises no error.
`fetchAll` now counts rows that came back with no linkage at all and, if a whole page is unlinked on
an endpoint we asked to sideload, logs at error level naming the expected `include`. A silent orphan
row is worse than a noisy one.

### 2. The vocabulary — ambiguity, not a stop-list, is the precision guard

`EntityBootstrap` was orphaned (zero production call sites) *and* insufficient. It only emitted
`url_host`/`email_domain` from `pd_companies.domain`, and on this workspace **0 of 687 companies
carry a domain** — so wiring it as-was would have inserted zero signals and rung 1 would have stayed
dead. Fixing the orphan alone was not the fix.

`understand-layer.md` §2.2 already specified name tokens as a source; only the domain half had been
built. Now both are.

**The interesting decision is how to keep keyword signals from lying.** A token minted against the
wrong client produces a *confident* wrong attribution, which is worse than no attribution — the user
has to notice it and undo it. My first instinct was a stop-list, and it is the wrong tool: it cannot
know that `video` appears in 40 projects across 30 clients while `engrid` belongs to exactly one.
That is a property of the data, not of English.

So the rule is structural: **a token becomes a signal only if every name containing it maps to the
same client.** A token pointing at two clients points at neither. It needs no maintenance and it
adapts as the workspace changes.

A small stop-list survives for one job the ambiguity test cannot do: `4site`, `internal`, `retainer`,
`meeting`, `pto`… name *our own* work. They pass the uniqueness test whenever a single client happens
to own the only project mentioning them, and would then attach a client to every unrelated session.

Two guards worth keeping:
- Projects with an empty `company_id` are skipped. Before stage 1 that was **every** project, and
  minting from them would have attached tokens to an empty client id — the same `""`-shaped
  corruption that hid the severed mirror.
- A project id rides along only when the token is unique to one *project* as well; otherwise the
  signal still resolves the client, which is the more valuable half.

**Rejected:** bootstrapping from `pd_tasks.title` (11,631 rows). Highest volume, lowest precision,
and stage 3 gives exact task attribution from URLs instead — evidence beats vocabulary.

Wired into `runPipelineOnce` before `DayClassifier`, since rung 1 reads what it writes. Idempotent
via `insertSignalIfAbsent`, and a test pins that re-running never overwrites a `user_confirmed`
signal — user rules outrank bootstrapped ones forever.

**Test churn worth noting:** the pre-existing `testCreatesDomainSignals` asserted `created == 2`.
It now sees 3 because the company name mints a keyword too. I rewrote the assertion to check the
signals it cares about rather than bumping the number — a test that pins a total count of sources
breaks every time a source is added, and tells you nothing about behaviour.

#### 2a. The bootstrap was about to cost 1,186 write transactions every 300 seconds

Caught by a pre-push review, then measured against the real workspace rather than estimated:

```
distinct tokens seen   : 1,746
UNAMBIGUOUS -> signals : 1,186   <-- one write transaction EACH
ambiguous (rejected)   :   560
```

`insertSignalIfAbsent` opens its own `writer.write { }` per call (`UnderstandDAO.swift:9-11`), and
I had wired the bootstrap into the 300s pipeline pass. So ~1,186 separate transactions every five
minutes, forever, to re-insert rows that already exist. Wiring an orphaned job without asking what it
costs to run *repeatedly* is its own failure mode — the job was written for a one-time setup path.

Two fixes:
- **Batch.** `insertSignalsIfAbsent([EntitySignal])` does the whole set in one transaction, same
  `onConflict: .ignore`, so a `user_confirmed` row is still never overwritten.
- **Throttle**, reusing the `sync_state` pattern the Slack `users.list` refresh already uses. Skips
  when the cache fingerprint (`companies:projects` counts) is unchanged AND the interval has not
  elapsed. A fresh Productive sync changes the fingerprint and re-derives immediately, so a new
  client does not stay invisible for a day.

**The daily re-derive is deliberate, and my first test asserted against it.** I wrote a test saying
"identical cache → never re-derive", which failed. The implementation was right and the test was
wrong: the fingerprint is only two counts, so a *renamed* project changes nothing it can see, and
without a periodic pass the vocabulary would go stale forever. One batched transaction a day is the
price of catching that. Corrected the test rather than weakening the code — the failing assertion
was the useful part.

Also validated by the measurement: the ambiguity guard rejects **560 of 1,746 tokens (32%)**. That
is a lot of confident wrong attributions not made.

### 3. Exact task attribution from URLs — and the review finding that invalidated stage 2's claim

**A post-push review found that the 1,185 keyword signals stage 2 minted were inert.** Nothing could
read them. `rung1` looked signals up by whole string — `signalsByValue["youtube.com"]` — while a
`keyword` signal's value is a name *token* like `engrid`. A hostname can never equal a token, Slack
context keys carry a conversation **id** rather than a channel name, and `app:` context keys were not
collected at all. So the arm that fires (`url_host`/`email_domain`) produced zero rows on a workspace
where 0 of 687 companies carry a domain, and the arm that produced 1,185 rows could never be read.

`classification-ladder.md` specified both arms all along — "context_key **(or dominant token set)**".
Only the first had been built. I wired a bootstrap to a rung that could not consume its output, and
the live rung breakdown said so plainly (47 classified, **all rung 2, zero rung 1**) — I reported that
number and attributed it to missing domain signals rather than chasing why rung 1 was still dark.
The measurable gain from stage 2 was **zero**; the 7 → 47 improvement came entirely from stage 1
un-starving rung 2's candidate builder.

Fixed by giving `rung1` a token arm. Deliberately more conservative than the exact-value arm: a
hostname match is unambiguous evidence, a single word in a window title is weaker, so bootstrapped
keyword hits score 0.82 against 0.85. A `user_confirmed` keyword keeps 0.97 — the user said so.
**Disagreement returns nil rather than picking a winner**: the bootstrap guarantees a token maps to
one client, but one session can contain tokens for two clients, and guessing there is the exact
confident-wrong-answer this design exists to avoid.

**The exact rung.** When a Productive task page is open its id is in the address bar — evidence, not
inference. It runs ahead of signal matching and is the only path that sets `sessions.task_id`, which
gap analysis needs to avoid re-suggesting logged time. It also fits this workspace specifically: the
captured hosts are overwhelmingly *tools* (Slack, Productive, EN, BugHerd), so the documented
`url_host → client` route resolves almost nothing.

Two details worth keeping:
- **Both URL shapes occur live** — `/task/18833587?taskActivityId=…` and `/tasks/task/18609405`.
  Matching only the documented one loses real attributions.
- **A filtered task list is not a task.** `/tasks?filter=<base64>` contains digits; scanning the raw
  URL for a number would mint a confident wrong task id. The query string is stripped before parsing,
  pinned by a test using the exact URL from the live data.

URLs are read from `activity_samples`, not `page_snapshots`, so this works even with Chrome's
"Allow JavaScript from Apple Events" toggle off.

### 3a. The rest of the review

- **Archived rows poisoned the vocabulary in both directions.** `db.companies()` returns every row.
  An archived "Acme Health" beside a live "Acme Foundation" makes `acme` ambiguous and silently
  suppresses the *live* client's own name; an archived-only client mints signals attributing today's
  work to a dead one. Now filtered. This likely explains a chunk of the 560 "rejected" tokens I
  reported as the guard working — some of it was data rot.
- **A company-name token was pinned to an arbitrary project.** Client "Zenith" with projects "Zenith
  Website" and "Newsletter Build" pinned every mention of the client's name to the website project.
  A project id now rides along only when the token came from a *project* name.
- **`time_entries` never asked for `project`,** which `PDMapper.timeEntry` reads — the same
  never-asked mechanism the `include` fix exists to solve, one field over.
- **A bootstrap throw could abort the whole pipeline pass**, skipping classification, rollups and
  retention. Now `try?`, matching what `DayClassifier` already does for its own signal write.
- **Numeric tokens** (`2018`, `101`, `40th`) passed the length floor and identify nothing — 12 of
  1,185 minted signals. Now filtered.

**Not acted on:** the review notes stage 1 multiplied rung-2's per-pass cost ~5× (candidates
1,652 → 13,283, ~340 ms on the main actor every 300s) because a linked mirror finally lets
`Classifier.init` build task candidates. That is the cost of the feature working, it is measured
rather than guessed, and 340 ms per five minutes is not worth optimising before the pipeline does
something with the result. Recorded so the next person sees it was a decision.

### 4. Wiring the engine — and the regression the wiring exposed

`SuggestionEngine` had six call sites, all tests. `runPipelineOnce` ran sessionize → classify →
recap → rollups → retention and never generated a suggestion, so `suggestions` sat at 0 for the
app's entire life while the recap rendered an empty card stack. Same class as `daily_rollups`:
a job that is never invoked cannot log a failure.

Three things had to change before wiring it was safe.

**Regeneration was destroying user decisions.** `generate` opened with `clearDay`, deleting and
reinserting every suggestion for the day. The pipeline runs every 300s, so a card marked Logged or
Tossed reverted to `pending` and reappeared within five minutes — the product's core loop silently
undoing itself. It also NULLed `decisions.suggestion_id` (the FK is `onDelete: .setNull`), orphaning
the audit trail the learning loop reads. Now only `pending` rows are cleared, and a group the user
already settled is skipped rather than re-proposed. The skip is keyed on **attribution identity**
(`kind|client|project|task`), not row id — the row is rebuilt every pass, so its id is meaningless
across regenerations.

**Config was decorative.** `suggestions.increment_minutes`, `round_up_bias` and
`standalone_threshold_minutes` were read in exactly one place — `SettingsView`, where they were only
*displayed*. The engine hardcoded its defaults. Now passed through, pinned by tests that set a
30-minute increment and a 45-minute threshold and assert the output changes.

**Gap analysis could finally work at all.** It keys on `pd_time_entries.task_id`, which was NULL for
every row until the `include=` fix. The test asserting an already-logged hour is not re-suggested
would have passed vacuously before stage 1 — there was nothing to match against.

#### The regression the live numbers caught

Adding the rung-1 keyword arm moved sessions from task-level rung-2 attribution to client-only
rung-1: `with_task` fell **47 → 43** while attribution rose 47 → 63. A signal match resolves the
*client* and rarely names a task; rung 2 can name one. Preferring rung 1 wholesale traded a more
useful answer for a more confident one — and a time entry needs a task.

Fixed by merging rather than choosing: when rung 1 matched on a keyword and rung 2 independently
agrees on the same client while being more specific, take rung 2's project/task with rung 1's
confidence. Two independent signals agreeing is stronger evidence than either alone. Only the
live numbers surfaced this — every unit test still passed.

Live after stages 1–3: **63 of 89 of today's sessions attributed (71%)**, up from 7, with **20 at
rung 1** where there had never been a single one.

### 5. Closing the learning loop

Three orphans, all on the path between "the app guessed" and "the app learns".

**`DecisionRecorder` was bypassed.** `RecapWindow.handle` wrote `updateSuggestionStatus` +
`insertDecision` by hand — the same two rows — and skipped the one thing `DecisionRecorder` adds:
the `user_confirmed` signal write. `user_confirmed` outranks `bootstrapped` and `inferred` forever,
so it is the entire correction channel. `RecapView`'s own doc comment said "the app wires it to
`DecisionRecorder`"; it did not. Accepting a suggestion taught the system nothing.

Now routed through it. The interesting question was *what* to confirm: a suggestion does not record
which signal produced it. The durable thing is the **context key of the sessions behind it** — a host
or Slack conversation that will recur tomorrow — so accepting promotes that.

Two deliberate restrictions:
- **Only on accept.** Tossing says the attribution was *wrong*; confirming it would teach the
  opposite of what the user meant.
- **Never an `app:` key.** Those name a tool. Confirming `app:com.apple.mail` would attribute every
  future use of Mail to whichever client happened to be on screen first — a rule that gets more
  wrong the longer it survives, and `user_confirmed` means it would outrank everything while doing so.

**`ResolutionQuestionGenerator` had no caller**, so the recap's Questions section was permanently
empty and the *manual* repair channel was closed alongside the automatic one. Wired into the
pipeline; one question per recurring unresolved host, idempotent across passes.

**No recap scheduler existed.** `config.recap.time` was decoded, shown in Settings, dumped into
diagnostics, and read by nothing that could act on it — there was no wall-clock timer anywhere in
the tree. The recap opened only if the user remembered to click "Open recap…". A recap nobody is
prompted to look at is a database, not a product.

`AppEnvironment` sets a flag rather than opening the window itself: it lives in the package and has
no access to SwiftUI's `openWindow`, which exists only in the app shell. The shell observes the flag.
That keeps the module boundary intact instead of dragging window management into the library.
A malformed `recap.time` logs and schedules nothing rather than crashing or firing at a surprising
hour — pinned for `""`, `"17"`, `"5pm"`, `"25:00"`, `"17:99"`.

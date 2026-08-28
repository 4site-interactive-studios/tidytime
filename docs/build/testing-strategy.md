# Testing strategy

How TidyTime is tested: fast `swift test` unit tests over `TidyKit`, recorded fixtures instead of live
network, an in-memory GRDB database per test, and the **guardrail tests** that turn the product's
non-negotiable invariants into red/green checks. Ends by tying every phase's acceptance criteria to a
concrete verification method.

**Related:** [../README.md](../README.md) (doc index) · [../guardrails.md](../guardrails.md) (G1–G9) ·
[../architecture/module-map.md](../architecture/module-map.md) ·
[environment-setup.md](environment-setup.md) · [../architecture/data-model.md](../architecture/data-model.md) ·
[../../PLAN.md](../../PLAN.md) §11

**Status:** build-ready · **Runner:** `swift test` (SwiftPM) via `make test` · **DB:** in-memory GRDB ·
**Network:** recorded fixtures only · **Last verified:** 2026-07-23

---

## 1. Principles

1. **No live network in unit tests.** Every API client sits behind a protocol
   (`ProductiveClient`, `IngestSource`, `AIProvider`, `BrowserAdapter`, `SensitivityGate`,
   `SecretStore`, `Clock` — see [../architecture/module-map.md](../architecture/module-map.md) §
   "Protocol seams"). Tests inject a fake that replays **recorded fixtures** (canned JSON captured
   once from the real service, with secrets scrubbed). This keeps tests deterministic and offline.
2. **In-memory DB per test.** GRDB opens `DatabaseQueue()` with no path → a fresh SQLite database in
   memory, migrated to the current schema, thrown away at test end. No shared state, no fixtures on
   disk, parallel-safe.
3. **Injectable time.** A `Clock` protocol replaces `Date()`/wall-clock so sessionization, retention
   windows, budget-day rollovers, and nudge rate-limits are tested with a deterministic clock.
4. **Guardrails are tests, not vibes.** Each invariant in [../guardrails.md](../guardrails.md) has a
   corresponding test here; "we'll be careful" is not an enforcement mechanism (§4).
5. **Fast inner loop.** `make test` runs `swift test` against the package directly — no Xcode project,
   no signing, no `.app`. Sub-second-to-seconds; run it constantly.

```bash
make test                    # cd Packages/TidyKit && swift test  (all suites)
cd Packages/TidyKit && swift test --filter Guardrail   # just the guardrail suites
```

## 2. Where tests live

`Package.swift` declares a single test target, **`TidyKitTests`**
(`Packages/TidyKit/Tests/TidyKitTests/`), which depends on **all eight** library products so any layer
can be exercised. Organize by subject in separate files/suites — one file per unit under test, plus a
dedicated group for guardrails:

```
Packages/TidyKit/Tests/TidyKitTests/
├─ Support/                       # test helpers (not a product)
│  ├─ TestDB.swift                # in-memory GRDB + migrator
│  ├─ Fixtures.swift              # load recorded JSON from Fixtures/
│  ├─ FakeClock.swift            # deterministic Clock
│  ├─ FakeSecretStore.swift      # in-memory SecretStore
│  └─ FakeAIProvider.swift       # scripted AIProvider for router tests
├─ Fixtures/                      # recorded API responses (secrets scrubbed)
│  ├─ productive/ …  fathom/ …  google/ …  slack/ …  fireworks/ …
├─ Store/ …  Capture/ …  Ingest/ …  Understand/ …  Suggest/ …  Surface/ …
└─ Guardrails/                    # G1–G9 tests (§4) — must stay green to merge
```

> The [module map](../architecture/module-map.md) speaks of "a matching test suite per target"; in
> practice that's one `TidyKitTests` target partitioned into per-layer suites (files), because a
> SwiftPM test target can cover multiple library targets. Keep suite names aligned to the layer under
> test.

Examples use **Swift Testing** (`import Testing`, `@Test`, `#expect` — the Xcode 16 / Swift 6 default);
XCTest is equally acceptable. Match whatever [../conventions/swift-style.md](../conventions/swift-style.md)
settles on.

## 3. The two fixtures: in-memory DB and recorded API

**In-memory GRDB.** A helper opens a fresh queue and runs the real migrator, so tests exercise the
actual schema from [../architecture/data-model.md](../architecture/data-model.md):

```swift
// Support/TestDB.swift
import GRDB
import TidyStore

enum TestDB {
    /// Fresh in-memory DB, migrated to the current schema. One per test.
    static func migrated() throws -> DatabaseQueue {
        let dbq = try DatabaseQueue()          // no path ⇒ in-memory
        try Migrations.all.migrate(dbq)        // the shipped DatabaseMigrator (v1-baseline, …)
        return dbq
    }
}

@Test func retentionPurgesRawRowsPastWindow() throws {
    let dbq = try TestDB.migrated()
    let clock = FakeClock(now: 1_800_000_000)
    // seed an activity_sample 91 days old and one 1 day old …
    try RetentionJob(clock: clock, retentionDays: 90).run(dbq)
    // assert the 91-day row is gone, the 1-day row remains (guardrail G9).
}
```

**Recorded API fixtures.** Capture one real response per endpoint, **scrub secrets**, commit under
`Fixtures/`, and replay through the protocol seam. No `URLSession` reaches the wire in a unit test.

```swift
// A fake ProductiveClient returns fixture JSON; the sync engine under test never hits the network.
struct FakeProductiveClient: ProductiveClient {
    func get(_ path: String, query: [String: String]) async throws -> Data {
        try Fixtures.data("productive/\(Fixtures.slug(path, query)).json")
    }
    // No mutating methods exist on the protocol at all (guardrail G1, §4).
}
```

Fixture rules: never commit a real token, org id, or personal data (guardrail
[G6](../guardrails.md#g6--secrets-live-in-the-keychain-only)); scrub emails/domains to
`example.org` unless the test asserts on domain matching; keep them small (trim long transcripts to
the utterances the test needs).

## 4. Guardrail tests (must exist; must stay green)

Each maps to an invariant in [../guardrails.md](../guardrails.md). These block merges — the Definition
of Done in [../../CLAUDE.md](../../CLAUDE.md) requires them green.

### G1 — no non-GET request can reach `api.productive.io`

Two layers of defense, both tested:

1. **Type-level:** `ProductiveClient` exposes **no** mutating method — there is no API to build a
   `POST`/`PUT`/`PATCH`/`DELETE`. A test asserts the request builder rejects any method but `GET`.

```swift
@Test func productiveRequestBuilderRefusesNonGET() throws {
    for method in ["POST", "PUT", "PATCH", "DELETE"] {
        #expect(throws: ProductiveError.methodNotAllowed) {
            _ = try ProductiveRequest.build(path: "time_entries", method: method)  // DEBUG: fatal/throw
        }
    }
    // GET builds fine:
    #expect(throws: Never.self) { _ = try ProductiveRequest.build(path: "time_entries", method: "GET") }
}
```

2. **Behavioral:** run the Phase 2 sync against fixtures behind a recording transport that **records
   every outbound request**, then assert **every** request to host `api.productive.io` used method
   `GET`. Guards against a future code path sneaking a write in.

### G3 — `TidyCapture` contains no `CGWindowList` window-name usage

A source-scanning test greps the `TidyCapture` sources; window titles must come from the Accessibility
API only ([../reference/macos-permissions-tcc.md](../reference/macos-permissions-tcc.md) §1). Locate
the sources relative to the test file:

```swift
@Test func captureNeverReadsCGWindowListNames() throws {
    // …/Packages/TidyKit/Tests/TidyKitTests/Guardrails/… → …/Sources/TidyCapture
    let root = URL(filePath: #filePath).deletingLastPathComponent()  // Guardrails/
        .deletingLastPathComponent().deletingLastPathComponent()      // TidyKitTests/ Tests/
        .deletingLastPathComponent()                                  // TidyKit/
        .appending(path: "Sources/TidyCapture")
    let banned = ["CGWindowListCopyWindowInfo", "kCGWindowName", "CGWindowList"]
    for file in try swiftFiles(under: root) {
        let src = try String(contentsOf: file, encoding: .utf8)
        for token in banned {
            #expect(!src.contains(token), "\(file.lastPathComponent) uses \(token) — violates G3")
        }
    }
}
```

Also assert no `kTCCServiceScreenCapture` / Screen Recording request exists anywhere in the build.

### G2 — a seeded sensitive phrase reaches **no** outbound payload

The sensitivity gate fails closed. Seed a known phrase into a fixture transcript, run it through the
gate and the cloud-payload builder, and assert the phrase appears in **none** of the bytes written to
the outbound-payload log (the local `DEBUG`/opt-in record of exactly what is sent to Fireworks /
Anthropic). This is the Phase 6 acceptance mechanism.

```swift
@Test func sensitivePhraseNeverLeavesTheDevice() throws {
    let secret = "discussing PIP for Jordan"                 // trips personnel/performance keywords
    let transcript = Fixtures.transcript(seededWith: secret) // sensitive phrase embedded mid-utterance
    let log = InMemoryOutboundPayloadLog()

    let gate = KeywordSensitivityGate(config: .defaults)     // ships non-empty defaults; empty ≠ disabled
    let router = AIRouter(providers: [.fireworks: RecordingProvider(log: log)], gate: gate, /* … */)
    _ = try await router.classifyTranscript(transcript)      // gate runs BEFORE any cloud dispatch

    let sentBytes = log.allBytes()
    #expect(!sentBytes.contains(secret))                     // never transmitted
    // And the resulting suggestion fell back to a generic task with a bland note:
    #expect(router.lastResult?.isSensitive == true)
}
```

Cloud clients accept only `GatedPayload` values that the gate can produce, so "forgot to gate" is a
compile error, not a runtime slip (guardrail G2). Uncertainty resolves to **sensitive**.

### G6 — the logger never emits secret material

`TidyLog` redacts anything token-shaped; secrets live in the Keychain only. Feed a secret through the
logger and assert it never appears in the emitted string, and that the outbound-payload log strips
auth headers.

```swift
@Test func loggerRedactsSecrets() {
    let sink = CapturingLogSink()
    let log = TidyLog(sink: sink)
    log.info("auth", metadata: ["Authorization": "Bearer sk-live-DEADBEEF", "token": "xoxp-1-abc"])
    let out = sink.text
    #expect(!out.contains("DEADBEEF"))
    #expect(!out.contains("xoxp-1-abc"))
    #expect(out.contains("<redacted>"))
}
```

### G5 — every cloud call writes an `ai_calls` row and honors budget caps

Two assertions against the [`ai_calls`](../architecture/data-model.md) ledger and the budget gate:

1. **Metering:** after any successful cloud call, exactly one `ai_calls` row exists with the right
   `provider`, `model`, `job_type`, token counts, computed `cost_usd`, and `outcome = 'ok'`.
2. **Capping:** an over-budget call is **refused before dispatch** — the provider is **not** invoked,
   and a row is written with `outcome = 'refused_budget'`.

```swift
@Test func cloudCallIsMeteredAndCapped() async throws {
    let dbq = try TestDB.migrated()
    let provider = FakeAIProvider(reply: .ok(inputTokens: 1200, outputTokens: 300))
    let router = AIRouter(db: dbq, providers: [.fireworks: provider],
                          budget: Budget(dailyCapUSD: ["fireworks": 0.01]),   // tiny cap
                          prices: .fixture)                                   // kimi $0.95/$4.00 per Mtok

    // First call fits under cap → metered ok.
    _ = try await router.run(job: .sessionBatch(fixtureSessions))
    let rows = try AICall.fetchAll(dbq)
    #expect(rows.count == 1)
    #expect(rows[0].provider == "fireworks" && rows[0].outcome == "ok")
    #expect(rows[0].cost_usd > 0)

    // Next call exceeds the daily cap → refused before dispatch, provider untouched.
    _ = try? await router.run(job: .sessionBatch(fixtureSessions))
    #expect(provider.callCount == 1)                                   // NOT called the second time
    let refused = try AICall.filter(Column("outcome") == "refused_budget").fetchAll(dbq)
    #expect(refused.count == 1)
}
```

Related G-checks worth a test each: **G4** (router short-circuits — a session a rule/lexical match
settles never reaches a cloud provider); **G9** (retention job purges raw rows past the window — shown
in §3); **G7** is verified out-of-band via `codesign` ([signing-and-tcc.md](signing-and-tcc.md) §7),
not a `swift test`.

## 5. Phase acceptance → verification method

Each phase ([../../PLAN.md](../../PLAN.md) §11, [../phases/](../phases/)) ends in a human-verifiable
check. Map every one to how it's proven — automated where possible, manual (doctor view / real day)
where the criterion is inherently observational.

| Phase | Acceptance criterion (abridged) | Verification method |
|---|---|---|
| **0 Skeleton** | icon in menu bar, survives reboot; doctor shows DB/config paths + permission status | manual: `make run`, reboot, open doctor. Automated: migrator applies clean on in-memory DB; `make doctor` prints paths |
| **1 Capture** | a full day reads back as a coherent session timeline incl. page snapshots; quiet CPU; no gaps across sleep/lock | unit: sessionization over recorded sample streams (detours < 120 s coalesce); retention purge test (G9). Manual: run a day, inspect timeline in doctor; watch CPU |
| **2 Productive** | local cache matches Productive's UI for your week; cached task opens in Productive | unit: sync engine over `Fixtures/productive/*` upserts `pd_*` rows correctly; **G1** no-write test. Manual: eyeball a week vs. the web app; click a deep link |
| **3 Meetings/Calendar** | yesterday's meetings show real recorded durations + attendees; a long gap prompts | unit: Fathom parse → `meetings.duration_seconds` from `recording_*`; Google `events.list` fixture → `calendar_events`; away-gap → prompt logic with `FakeClock`. Manual: check yesterday; force an idle gap |
| **4 Slack** | a morning of Slack activity attributes to the right conversations, incl. phone-sent messages | unit: history fixture → `slack_messages` upsert keyed `(conversation_id, ts)`, `is_self` set. Manual: compare a morning against Slack |
| **5 Recap/Rules** | reconcile a real day in < 10 min; a forgotten billable block made it into Productive | unit: rung-1 rules + rung-2 lexical classification; rounding + round-up bias; pool roll-up ≥ 15 min; gap analysis vs. `pd_time_entries`. Manual: reconcile a real day, time it |
| **6 Intelligence** | per-client split w/ timestamps; seeded sensitive phrase in **no** cloud payload; every cloud call in the ledger reconciles; nudges under cap | unit: **G2** payload test, **G5** meter+cap test, transcript-split math sums to `recording` duration, nudge rate-limit with `FakeClock`. Manual: run a mixed call; reconcile ledger vs. provider dashboard |

Rule of thumb: anything a fixture + in-memory DB can prove **must** have a unit test; the observational
criteria (CPU quiet, "reconcile in under ten minutes", grants stay after rebuild) are verified with the
doctor view, `codesign`, or a real day — and their supporting logic is still unit-tested underneath.

## 6. Definition of done (testing slice)

From [../../CLAUDE.md](../../CLAUDE.md):

- [ ] `make build` compiles and `make test` is green — **including** all guardrail suites (§4).
- [ ] New behavior that a fixture + in-memory DB can exercise has a unit test.
- [ ] Schema change ⇒ a **new** GRDB migration (never edit a shipped one) + `data-model.md` updated;
      a test seeds/asserts the migration.
- [ ] No fixture contains a real secret or personal data (G6); no test hits the live network.
- [ ] The guardrail relevant to the change (Productive read-only, no `CGWindowList`, gate-before-cloud,
      metered+capped cloud, redacted logs) has a green test.

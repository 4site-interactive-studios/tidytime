import XCTest
import Foundation
import GRDB
import TidyCore
@testable import TidyStore
@testable import TidyCapture
import TidySuggest
import TidyAI

/// Regression tests from the round-2 blind review (2026-07-25) of the post-review delta.
/// Each fixed finding gets a test that fails if the defect returns.

// MARK: - R1-1 / R3-7 — one signature definition, three call sites

final class ContextSignatureTests: XCTestCase {
    func testDropsQueryAndFragment() {
        XCTAssertEqual(ContextSignature.normalizedPath("https://claude.ai/chat/aaa?msg=99#bottom"), "/chat/aaa")
    }
    func testRootPathIsNil() {
        XCTAssertNil(ContextSignature.normalizedPath("https://example.org/"))
        XCTAssertNil(ContextSignature.normalizedPath("https://example.org"))
    }
    func testTrimsTrailingSlashesAndLowercases() {
        XCTAssertEqual(ContextSignature.normalizedPath("https://Example.org/Chat/AAA///"), "/chat/aaa")
    }
    func testTruncatesLongPath() {
        let long = "https://x.org/" + String(repeating: "a", count: 300)
        XCTAssertEqual(ContextSignature.normalizedPath(long)?.count, 120)
    }
    func testNilAndUnparseable() {
        XCTAssertNil(ContextSignature.normalizedPath(nil))
        // A bare non-URL string parses as a relative path, so it becomes its own discriminator
        // rather than collapsing every unparseable value together. `ContextKey.derive` still falls
        // back to `app:` for these (it uses `host(from:)`), which is what matters for rung-1 rules.
        XCTAssertEqual(ContextSignature.normalizedPath("not a url"), "not a url")
        XCTAssertNil(ContextSignature.host(from: "not a url"))
    }
    func testNormalizedURLDropsSchemeAndWWW() {
        XCTAssertEqual(ContextSignature.normalizedURL("https://www.Example.org/A/b?x=1#f"), "example.org/a/b")
        XCTAssertEqual(ContextSignature.normalizedURL("http://example.org/a/b"),
                       ContextSignature.normalizedURL("https://example.org/a/b"))
    }
    func testNormalizedURLKeepsPort() {
        XCTAssertNotEqual(ContextSignature.normalizedURL("http://localhost:3000/a"),
                          ContextSignature.normalizedURL("http://localhost:8080/a"))
    }
    func testUnparseableStaysDistinct() {
        XCTAssertNotEqual(ContextSignature.normalizedURL("about:blank"),
                          ContextSignature.normalizedURL("weird string"))
    }
    func testIdentityQueryKeysRetainedAndOrderIndependent() {
        let p = ContextSignature.Policy(identityQueryKeys: ["project"])
        XCTAssertEqual(ContextSignature.normalizedURL("https://x.org/a?project=acme&msg=9", policy: p),
                       ContextSignature.normalizedURL("https://x.org/a?msg=1&project=acme", policy: p))
        XCTAssertNotEqual(ContextSignature.normalizedURL("https://x.org/a?project=acme", policy: p),
                          ContextSignature.normalizedURL("https://x.org/a?project=beta", policy: p))
    }
    func testNonIdentityQueryAlwaysDropped() {
        let p = ContextSignature.Policy(identityQueryKeys: ["project"])
        XCTAssertEqual(ContextSignature.normalizedURL("https://x.org/a?msg=1", policy: p),
                       ContextSignature.normalizedURL("https://x.org/a?msg=2", policy: p))
    }
    func testTitleBadgeStrippedAndWhitespaceCollapsed() {
        XCTAssertEqual(ContextSignature.normalizedTitle("(3)  Foo   Bar"),
                       ContextSignature.normalizedTitle("(12) foo bar"))
    }

    /// The instrument that fails if capture and the metric ever re-diverge.
    func testCaptureAndMetricAgreeOnEveryCase() {
        let cases: [(String, String?, String?)] = [
            ("com.google.Chrome", "New chat", "https://claude.ai/chat/aaa?msg=1"),
            ("com.google.Chrome", "New chat", "https://claude.ai/chat/aaa?msg=99#x"),
            ("com.tinyspeck.slack", "(3) Slack", nil),
            ("com.tinyspeck.slack", "(4) Slack", nil),
            ("com.google.Chrome", "t", "https://x.org/a/"),
            ("com.a", nil, "not a url"),
        ]
        for (bundle, title, url) in cases {
            let ctx = FrontmostContext(appBundleId: bundle, appName: bundle, windowTitle: title,
                                       isBrowser: url != nil, url: url)
            let sample = ActivitySample(startedAt: 0, endedAt: 1, appBundleId: bundle, appName: bundle,
                                        windowTitle: title, isBrowser: url != nil, url: url,
                                        source: "switch", createdAt: 0)
            XCTAssertEqual(CaptureCoordinator.signature(ctx),
                           ContextSwitchAnalyzer.signature(sample),
                           "capture/metric signatures diverged for \(bundle)/\(title ?? "-")/\(url ?? "-")")
        }
    }
}

final class CaptureChurnGatingTests: XCTestCase {
    private func makeCoordinator(_ db: AppDatabase, adapter: FakeBrowserAdapter,
                                 reader: MutableFrontmostReader) -> CaptureCoordinator {
        CaptureCoordinator(reader: reader, browser: adapter,
                           recorder: SampleRecorder(db: db, clock: FixedClock(Date(timeIntervalSince1970: 1000))))
    }

    func testQueryChurnCreatesNoNewSampleAndNoExtraPageTextCall() throws {
        let db = try AppDatabase.inMemory()
        let adapter = FakeBrowserAdapter(tab: BrowserTab(url: "https://claude.ai/chat/aaa?msg=1", title: "New chat"),
                                         pageText: "hello")
        let reader = MutableFrontmostReader(FrontmostContext(appBundleId: "com.google.Chrome", appName: "Chrome",
                                                             windowTitle: "New chat", isBrowser: true))
        let coord = makeCoordinator(db, adapter: adapter, reader: reader)

        XCTAssertTrue(try coord.poll())
        for n in 2...6 {
            adapter.tab = BrowserTab(url: "https://claude.ai/chat/aaa?msg=\(n)#bottom", title: "New chat")
            XCTAssertFalse(try coord.poll(), "query churn must not record a new sample")
        }
        XCTAssertEqual(try db.tableRowCounts()["activity_samples"], 1)
        XCTAssertEqual(adapter.pageTextCalls, 1, "churn must not re-fire the expensive innerText grab")
    }

    func testUnreadBadgeChurnCreatesNoNewSample() throws {
        let db = try AppDatabase.inMemory()
        let reader = MutableFrontmostReader(FrontmostContext(appBundleId: "com.slack", appName: "Slack",
                                                             windowTitle: "(3) acme-project"))
        let coord = CaptureCoordinator(reader: reader, browser: nil,
                                       recorder: SampleRecorder(db: db, clock: FixedClock(Date(timeIntervalSince1970: 1))))
        XCTAssertTrue(try coord.poll())
        reader.value = FrontmostContext(appBundleId: "com.slack", appName: "Slack", windowTitle: "(4) acme-project")
        XCTAssertFalse(try coord.poll())
        XCTAssertEqual(try db.tableRowCounts()["activity_samples"], 1)
    }

    func testRealPathChangeStillCreatesNewSample() throws {
        let db = try AppDatabase.inMemory()
        let adapter = FakeBrowserAdapter(tab: BrowserTab(url: "https://claude.ai/chat/aaa", title: "New chat"),
                                         pageText: "a")
        let reader = MutableFrontmostReader(FrontmostContext(appBundleId: "com.google.Chrome", appName: "Chrome",
                                                             windowTitle: "New chat", isBrowser: true))
        let coord = makeCoordinator(db, adapter: adapter, reader: reader)
        XCTAssertTrue(try coord.poll())
        adapter.tab = BrowserTab(url: "https://claude.ai/chat/bbb", title: "New chat")
        XCTAssertTrue(try coord.poll(), "a different chat id must still register")
        XCTAssertEqual(try db.tableRowCounts()["activity_samples"], 2)
    }

    /// Raw URL is still what gets STORED (the ledger stays raw so the metric can be recomputed).
    func testStoresRawURLNotNormalized() throws {
        let db = try AppDatabase.inMemory()
        let adapter = FakeBrowserAdapter(tab: BrowserTab(url: "https://claude.ai/chat/aaa?msg=1", title: "t"), pageText: "x")
        let reader = MutableFrontmostReader(FrontmostContext(appBundleId: "com.google.Chrome", appName: "Chrome",
                                                             windowTitle: "t", isBrowser: true))
        _ = try makeCoordinator(db, adapter: adapter, reader: reader).poll()
        XCTAssertEqual(try db.samples(from: 0, to: 10_000).first?.url, "https://claude.ai/chat/aaa?msg=1")
    }
}

final class ContextSwitchChurnTests: XCTestCase {
    private func sample(_ s: Int64, _ e: Int64, title: String?, url: String? = nil) -> ActivitySample {
        ActivitySample(startedAt: s, endedAt: e, appBundleId: "com.google.Chrome", appName: "Chrome",
                       windowTitle: title, isBrowser: url != nil, url: url, source: "switch", createdAt: 0)
    }

    func testQueryChurnCountsAsZeroSwitches() {
        let samples = (0..<10).map { i in
            sample(Int64(i) * 60, Int64(i + 1) * 60, title: "New chat",
                   url: "https://claude.ai/chat/aaa?msg=\(i)")
        }
        let m = ContextSwitchAnalyzer().analyze(samples, now: 600)
        XCTAssertEqual(m.switchCount, 0, "per-message churn must not read as context switching")
        XCTAssertEqual(m.uniqueContexts, 1)
        XCTAssertEqual(m.briefSwitches, 0)
        XCTAssertEqual(m.longestFocusSeconds, 600)
    }

    func testBadgeChurnCountsAsZeroSwitches() {
        let m = ContextSwitchAnalyzer().analyze([
            sample(0, 60, title: "(1) Slack"), sample(60, 120, title: "(2) Slack"),
        ], now: 120)
        XCTAssertEqual(m.switchCount, 0)
    }

    func testDistinctPathsStillCountAsSwitches() {
        let m = ContextSwitchAnalyzer().analyze([
            sample(0, 60, title: "New chat", url: "https://claude.ai/chat/aaa"),
            sample(60, 120, title: "New chat", url: "https://claude.ai/chat/bbb"),
        ], now: 120)
        XCTAssertEqual(m.switchCount, 1, "genuinely different chats must still count")
    }

    // R1-2: unattended time is not focus — via the precise away-gap path.
    func testAwayGapIsClippedOutOfFocus() {
        // One context spanning 15h, but an away gap covers all but the first 10 minutes of it.
        let gap = AwayGap(startedAt: 600, endedAt: 54_000, durationSeconds: 53_400, cause: "sleep", createdAt: 0)
        let m = ContextSwitchAnalyzer().analyze([sample(0, 54_000, title: "Slack")], now: 54_000, awayGaps: [gap])
        XCTAssertEqual(m.longestFocusSeconds, 600, "an away gap must not count as focus")
        XCTAssertEqual(m.activeSeconds, 600, "unattended time must not inflate active seconds")
    }

    // Fallback heuristic when NO away gap was recorded: an implausibly long span is not focus.
    func testImplausiblyLongSpanIsDroppedWithoutAwayGapEvidence() {
        let m = ContextSwitchAnalyzer(maxPlausibleFocusSeconds: 7200).analyze([
            sample(0, 54_000, title: "Slack"),          // 15h — not credible as focus
            sample(54_000, 54_600, title: "VS Code"),   // a real 10-minute run
        ], now: 54_600)
        XCTAssertEqual(m.longestFocusSeconds, 600)
        XCTAssertEqual(m.activeSeconds, 600)
    }

    // …but genuine deep work is still focus. This is why the ceiling is generous, not idleThreshold.
    func testOneHourOfDeepWorkStillCountsAsFocus() {
        let m = ContextSwitchAnalyzer().analyze([sample(0, 3600, title: "writing")], now: 3600)
        XCTAssertEqual(m.longestFocusSeconds, 3600)
        XCTAssertEqual(m.switchCount, 0)
    }

    func testOpenTrailingSampleClampedToNow() {
        let open = ActivitySample(startedAt: 0, endedAt: nil, appBundleId: "com.a", appName: "A",
                                  windowTitle: "x", source: "switch", createdAt: 0)
        let m = ContextSwitchAnalyzer(maxPlausibleFocusSeconds: 100_000).analyze([open], now: 300)
        XCTAssertEqual(m.activeSeconds, 300, "an open sample must not stretch past now")
    }

    func testOddCountMedian() {
        let m = ContextSwitchAnalyzer().analyze([
            sample(0, 10, title: "a"), sample(10, 60, title: "b"), sample(60, 360, title: "c"),
        ], now: 360)
        XCTAssertEqual(m.medianDwellSeconds, 50, accuracy: 0.01)
    }

    // R2-03: the run-collapsing branch (two adjacent samples with an identical signature).
    func testAdjacentIdenticalSignaturesCollapseIntoOneRun() {
        let m = ContextSwitchAnalyzer().analyze([
            sample(0, 60, title: "same"), sample(60, 120, title: "same"), sample(120, 180, title: "other"),
        ], now: 180)
        XCTAssertEqual(m.switchCount, 1)
        XCTAssertEqual(m.longestFocusSeconds, 120, "the merged run should be 120s")
    }
}

// MARK: - R1-3 / R2-05 — page text scoped to the session's own context

final class PageTextScopingTests: XCTestCase {
    func testHostScopingExcludesAbsorbedDetour() throws {
        let db = try AppDatabase.inMemory()
        let id = try db.insertSample(ActivitySample(startedAt: 0, endedAt: 100, appBundleId: "c", appName: "c",
                                                    isBrowser: true, url: "https://client.org/a", source: "switch", createdAt: 0))
        try db.insertPageSnapshot(PageSnapshot(sampleId: id, capturedAt: 10, url: "https://client.org/a",
                                               contentHash: "h1", text: "client work", textBytes: 11))
        try db.insertPageSnapshot(PageSnapshot(sampleId: id, capturedAt: 90, url: "https://unrelated.example/x",
                                               contentHash: "h2", text: "foreign detour text", textBytes: 19))
        let scoped = try db.pageTexts(from: 0, to: 200, limit: 3, host: "client.org")
        XCTAssertEqual(scoped, ["client work"], "an absorbed detour must not supply the evidence")
        // Unscoped would have returned the newest (foreign) text first.
        XCTAssertEqual(try db.pageTexts(from: 0, to: 200, limit: 3).first, "foreign detour text")
    }

    func testLimitAndOrderingAndWindow() throws {
        let db = try AppDatabase.inMemory()
        let id = try db.insertSample(ActivitySample(startedAt: 0, endedAt: 100, appBundleId: "c", appName: "c",
                                                    source: "switch", createdAt: 0))
        for i in 1...5 {
            try db.insertPageSnapshot(PageSnapshot(sampleId: id, capturedAt: Int64(i), url: "https://x.org/\(i)",
                                                   contentHash: "h\(i)", text: "t\(i)", textBytes: 2))
        }
        try db.insertPageSnapshot(PageSnapshot(sampleId: id, capturedAt: 999, url: "https://x.org/out",
                                               contentHash: "out", text: "outside", textBytes: 7))
        let texts = try db.pageTexts(from: 0, to: 100, limit: 3)
        XCTAssertEqual(texts, ["t5", "t4", "t3"], "newest-first, capped, window-bounded")
    }
}

// MARK: - R2-02 — the v2 migration must work on a POPULATED database, not just a fresh one

final class MigrationUpgradePathTests: XCTestCase {
    func testV2AppliesToDatabaseWithExistingRollupRows() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        // Migrate only up to the pre-v2 state, then insert a rollup row the old schema allows.
        try Migrations.migrator().migrate(queue, upTo: "v1-ai")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO daily_rollups (day, observed_seconds, attributed_seconds, logged_minutes,
                                           billable_minutes, internal_minutes, per_client_json,
                                           ai_cost_usd, created_at, updated_at)
                VALUES ('2026-07-01', 3600, 1800, 60, 30, 30, '{}', 0.5, 1, 1)
                """)
        }
        // Now apply the rest — this is the upgrade path a real user's DB takes.
        try Migrations.migrator().migrate(queue)
        let row = try queue.read { db in try Row.fetchOne(db, sql: "SELECT * FROM daily_rollups WHERE day='2026-07-01'") }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?["context_switches"] as Int?, 0, "new NOT NULL column must default on existing rows")
        XCTAssertEqual(row?["ai_cost_usd"] as Double?, 0.5, "pre-existing data must survive the upgrade")
    }

    func testPageSnapshotIndexExists() throws {
        let db = try AppDatabase.inMemory()
        XCTAssertTrue(try db.appliedMigrations().contains("v2-page-snapshot-time-index"))
        let plan = try db.writer.read { d -> String in
            let rows = try Row.fetchAll(d, sql: "EXPLAIN QUERY PLAN SELECT text FROM page_snapshots WHERE captured_at >= 1 AND captured_at < 2")
            return rows.map { ($0["detail"] as String?) ?? "" }.joined(separator: " ")
        }
        XCTAssertTrue(plan.lowercased().contains("index"), "captured_at lookup should use an index, got: \(plan)")
    }
}

// MARK: - R3-1 — escalation rate must not count escalations in its own denominator

final class EscalationRateTests: XCTestCase {
    func testEscalationRateIsTierBasedNotVendorBased() throws {
        let db = try AppDatabase.inMemory()
        // 4 economy jobs on fireworks, plus 1 escalation — now also on fireworks.
        for i in 0..<4 {
            _ = try db.insertAICall(AICall(occurredAt: Int64(i), jobType: "session_batch", provider: "fireworks",
                                           model: "kimi", costUsd: 0.01, outcome: "ok"))
        }
        _ = try db.insertAICall(AICall(occurredAt: 99, jobType: "escalation", provider: "fireworks",
                                       model: "deepseek", costUsd: 0.02, outcome: "ok"))
        let dash = try DashboardBuilder(db: db).build(from: 0, to: 1000)
        // 1 escalation / 4 economy attempts = 0.25. Vendor-based counting gave 1/5 = 0.2.
        XCTAssertEqual(dash.escalationRate, 0.25, accuracy: 0.001,
                       "escalations must not be counted inside the economy denominator")
    }
}

// MARK: - R2-04 — the vacuous assertion, replaced with a concrete one

final class GroupingConcreteValueTests: XCTestCase {
    func testNativeGroupingKeyHasConcreteValue() {
        XCTAssertEqual(
            ContextKey.grouping(isBrowser: false, url: nil, appBundleId: "com.claude", windowTitle: "New chat"),
            "app:com.claude#new chat")
    }
    func testSeparateChatsByPathDecodes() throws {
        let dir = try TestSupport.makeTempDir(); defer { TestSupport.cleanup(dir) }
        let url = dir.appendingPathComponent("c.json")
        try #"{"capture":{"separate_chats_by_path":false,"identity_query_keys":["project"]}}"#
            .data(using: .utf8)!.write(to: url)
        let cfg = try ConfigLoader().load(from: url)
        XCTAssertFalse(cfg.capture.separateChatsByPath)
        XCTAssertEqual(cfg.capture.identityQueryKeys, ["project"])
        XCTAssertTrue(Config().capture.separateChatsByPath, "default stays true")
        XCTAssertEqual(Config().capture.identityQueryKeys, [])
    }
}

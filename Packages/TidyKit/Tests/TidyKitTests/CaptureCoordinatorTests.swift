import XCTest
import Foundation
import TidyCore
import TidyStore
import TidyCapture

final class CaptureCoordinatorTests: XCTestCase {
    private func make(_ reader: MutableFrontmostReader, browser: BrowserAdapter? = nil)
        throws -> (AppDatabase, FixedClock, CaptureCoordinator) {
        let db = try AppDatabase.inMemory()
        let clock = FixedClock(Date(timeIntervalSince1970: 1000))
        let recorder = SampleRecorder(db: db, clock: clock)
        return (db, clock, CaptureCoordinator(reader: reader, browser: browser, recorder: recorder))
    }

    /// A steady context is one open sample no matter how many times we poll (no DB bloat).
    func testUnchangedContextRecordsOnce() throws {
        let reader = MutableFrontmostReader(FrontmostContext(appBundleId: "com.a", appName: "A", windowTitle: "chat 1"))
        let (db, clock, coord) = try make(reader)
        XCTAssertTrue(try coord.poll())                                       // first poll records
        for _ in 0..<20 { clock.advance(by: 1); XCTAssertFalse(try coord.poll()) }  // unchanged → nothing new
        XCTAssertEqual(try db.tableRowCounts()["activity_samples"], 1)
    }

    /// Within ONE app, changing the window title (chat 1 → chat 2) creates a distinct sample —
    /// this is the sub-app granularity the tiered detection poll unlocks.
    func testWithinAppTitleChangeCreatesNewSample() throws {
        let reader = MutableFrontmostReader(FrontmostContext(appBundleId: "com.anthropic.claude", appName: "Claude", windowTitle: "chat 1"))
        let (db, clock, coord) = try make(reader)
        XCTAssertTrue(try coord.poll())                       // chat 1 → sample 1
        clock.advance(by: 1)
        XCTAssertFalse(try coord.poll())                      // still chat 1 → no new sample
        clock.advance(by: 1)
        reader.value?.windowTitle = "cowork"                  // switch view, same app
        XCTAssertTrue(try coord.poll())                       // → sample 2
        clock.advance(by: 1)
        reader.value?.windowTitle = "chat 1"                  // back to chat 1
        XCTAssertTrue(try coord.poll())                       // → sample 3 (distinct block)

        let samples = try db.samples(from: 0, to: 100_000)
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples.map(\.windowTitle), ["chat 1", "cowork", "chat 1"])
        XCTAssertTrue(samples.allSatisfy { $0.appBundleId == "com.anthropic.claude" })
    }

    /// A browser tab switch (same app, different URL) also creates a distinct sample.
    func testBrowserTabChangeCreatesNewSample() throws {
        let reader = MutableFrontmostReader(FrontmostContext(appBundleId: "com.google.Chrome", appName: "Chrome", isBrowser: true))
        let adapter = FakeBrowserAdapter(tab: BrowserTab(url: "https://claude.ai/chat/1", title: "chat 1"))
        let (db, clock, coord) = try make(reader, browser: adapter)
        XCTAssertTrue(try coord.poll())
        clock.advance(by: 1)
        adapter.tab = BrowserTab(url: "https://claude.ai/cowork", title: "cowork")
        XCTAssertTrue(try coord.poll())
        let samples = try db.samples(from: 0, to: 100_000)
        XCTAssertEqual(samples.map(\.url), ["https://claude.ai/chat/1", "https://claude.ai/cowork"])
    }

    /// Page text is captured on landing in a browser context and deduped on the slow content tick.
    func testContentCapturedOnceThenDeduped() throws {
        let reader = MutableFrontmostReader(FrontmostContext(appBundleId: "com.google.Chrome", appName: "Chrome", isBrowser: true))
        let adapter = FakeBrowserAdapter(tab: BrowserTab(url: "https://x.org/a", title: "A"), pageText: "hello world")
        let (db, _, coord) = try make(reader, browser: adapter)
        XCTAssertTrue(try coord.poll())                 // records sample + captures page text once
        try coord.captureContent()                       // same text → deduped
        try coord.captureContent()
        XCTAssertEqual(try db.tableRowCounts()["page_snapshots"], 1)
        adapter.pageText = "hello world updated"          // content changed
        try coord.captureContent()
        XCTAssertEqual(try db.tableRowCounts()["page_snapshots"], 2)
    }

    func testConfigCarriesFractionalIntervals() throws {
        let url = TestSupport.repoRoot().appendingPathComponent("config.example.json")
        let cfg = try ConfigLoader().load(from: url)
        XCTAssertEqual(cfg.capture.detectionIntervalSeconds, 1.0)
        XCTAssertEqual(cfg.capture.contentIntervalSeconds, 20.0)
        // fractional value round-trips
        let data = #"{ "capture": { "detection_interval_seconds": 0.5 } }"#.data(using: .utf8)!
        let dir = try TestSupport.makeTempDir(); defer { TestSupport.cleanup(dir) }
        let f = dir.appendingPathComponent("c.json"); try data.write(to: f)
        XCTAssertEqual(try ConfigLoader().load(from: f).capture.detectionIntervalSeconds, 0.5)
    }
}

import XCTest
import Foundation
import TidyCapture

final class ContextKeyTests: XCTestCase {
    func testBrowserUsesHostStrippingWWW() {
        XCTAssertEqual(ContextKey.derive(isBrowser: true, url: "https://docs.google.com/document/d/x", appBundleId: "com.google.Chrome"), "web:docs.google.com")
        XCTAssertEqual(ContextKey.derive(isBrowser: true, url: "https://www.example.org/a", appBundleId: "com.google.Chrome"), "web:example.org")
    }
    func testNonBrowserUsesBundle() {
        XCTAssertEqual(ContextKey.derive(isBrowser: false, url: nil, appBundleId: "com.tinyspeck.slackmacgap"), "app:com.tinyspeck.slackmacgap")
    }
    func testBrowserWithBadURLFallsBackToApp() {
        XCTAssertEqual(ContextKey.derive(isBrowser: true, url: "not a url", appBundleId: "com.google.Chrome"), "app:com.google.Chrome")
    }
}

final class PageTextPolicyTests: XCTestCase {
    func testTruncatesToByteBudget() {
        let p = PageTextPolicy(maxBytes: 10)
        let out = p.prepare("abcdefghijklmnop")
        XCTAssertEqual(out.text, "abcdefghij")
        XCTAssertEqual(out.bytes, 10)
    }
    func testDoesNotSplitMultibyteCharacter() {
        let p = PageTextPolicy(maxBytes: 3) // "é" is 2 bytes; 2+2 > 3 → only one fits
        let out = p.prepare("ééé")
        XCTAssertEqual(out.text, "é")
        XCTAssertLessThanOrEqual(out.bytes, 3)
    }
    func testHashStableAndDedup() {
        let p = PageTextPolicy()
        let a = p.prepare("hello world")
        let b = p.prepare("hello world")
        XCTAssertEqual(a.hash, b.hash)
        XCTAssertFalse(p.shouldStore(newHash: a.hash, previousHash: b.hash))
        XCTAssertTrue(p.shouldStore(newHash: a.hash, previousHash: nil))
        XCTAssertTrue(p.shouldStore(newHash: a.hash, previousHash: "different"))
    }
}

final class SessionizerTests: XCTestCase {
    private func slice(_ id: Int64, _ start: Int64, _ end: Int64, _ ctx: String, _ app: String = "com.app", _ title: String? = nil) -> SampleSlice {
        SampleSlice(id: id, start: start, end: end, contextKey: ctx, appBundleId: app, title: title)
    }

    func testMergesSameContext() {
        let s = Sessionizer(detourTolerance: 120, minSessionSeconds: 60)
        let out = s.sessions(from: [slice(1, 0, 100, "app:A"), slice(2, 100, 200, "app:A")])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].start, 0)
        XCTAssertEqual(out[0].end, 200)
        XCTAssertEqual(out[0].durationSeconds, 200)
        XCTAssertEqual(out[0].sampleIds, [1, 2])
    }

    func testAbsorbsBriefDetour() {
        let s = Sessionizer(detourTolerance: 120, minSessionSeconds: 60)
        // 30s detour to B, bounded by A on both sides → one A session
        let out = s.sessions(from: [
            slice(1, 0, 100, "app:A"), slice(2, 100, 130, "app:B"), slice(3, 130, 300, "app:A"),
        ])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].contextKey, "app:A")
        XCTAssertEqual(out[0].end, 300)
        XCTAssertEqual(out[0].sampleIds, [1, 2, 3])
    }

    func testLongSwitchBreaksSession() {
        let s = Sessionizer(detourTolerance: 120, minSessionSeconds: 60)
        let out = s.sessions(from: [
            slice(1, 0, 200, "app:A"), slice(2, 200, 400, "app:B"),
        ])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.map(\.contextKey), ["app:A", "app:B"])
    }

    func testDropsSubMinimumRuns() {
        let s = Sessionizer(detourTolerance: 120, minSessionSeconds: 60)
        // A run of 200s (kept), then a standalone 30s C run (dropped)
        let out = s.sessions(from: [
            slice(1, 0, 200, "app:A"), slice(2, 500, 530, "app:C"),
        ])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].contextKey, "app:A")
    }

    func testPrimaryAppIsLongestWithinRun() {
        let s = Sessionizer(detourTolerance: 300, minSessionSeconds: 1)
        // same context, two apps; app X dominates by duration
        let out = s.sessions(from: [
            slice(1, 0, 30, "web:docs.google.com", "com.google.Chrome"),
            slice(2, 30, 200, "web:docs.google.com", "com.google.Chrome"),
        ])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].primaryApp, "com.google.Chrome")
    }
}

final class AwayGapDetectorTests: XCTestCase {
    func testDetectsIdleGapAboveThreshold() {
        let d = AwayGapDetector(idleThresholdSeconds: 600)
        let slices = [
            SampleSlice(id: 1, start: 0, end: 100, contextKey: "app:A", appBundleId: "a"),
            SampleSlice(id: 2, start: 800, end: 900, contextKey: "app:A", appBundleId: "a"),
        ]
        let gaps = d.idleGaps(in: slices)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].start, 100)
        XCTAssertEqual(gaps[0].end, 800)
        XCTAssertEqual(gaps[0].cause, "idle")
    }
    func testIgnoresShortGap() {
        let d = AwayGapDetector(idleThresholdSeconds: 600)
        let slices = [
            SampleSlice(id: 1, start: 0, end: 100, contextKey: "app:A", appBundleId: "a"),
            SampleSlice(id: 2, start: 300, end: 400, contextKey: "app:A", appBundleId: "a"),
        ]
        XCTAssertTrue(d.idleGaps(in: slices).isEmpty)
    }
    func testExplicitGap() {
        let d = AwayGapDetector(idleThresholdSeconds: 600)
        let g = d.explicitGap(cause: "lock", from: 1000, to: 1300)
        XCTAssertEqual(g.durationSeconds, 300)
        XCTAssertEqual(g.cause, "lock")
    }
}

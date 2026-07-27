import XCTest
import Foundation
import TidyCore
import TidyStore
import TidyCapture

final class CaptureMigrationTests: XCTestCase {
    func testV1CaptureCreatesTables() throws {
        let db = try AppDatabase.inMemory()
        XCTAssertTrue(try db.appliedMigrations().contains("v1-capture"))
        let counts = try db.tableRowCounts()
        for table in ["activity_samples", "page_snapshots", "sessions", "away_gaps", "sync_state"] {
            XCTAssertNotNil(counts[table], "missing table \(table)")
        }
    }
}

final class SampleRecorderTests: XCTestCase {
    func testRecordClosesPreviousSample() throws {
        let db = try AppDatabase.inMemory()
        let clock = FixedClock(Date(timeIntervalSince1970: 1000))
        let recorder = SampleRecorder(db: db, clock: clock)

        _ = try recorder.record(FrontmostContext(appBundleId: "com.a", appName: "A"))
        clock.advance(by: 60)
        _ = try recorder.record(FrontmostContext(appBundleId: "com.b", appName: "B"))

        let samples = try db.samples(from: 0, to: 10_000)
        XCTAssertEqual(samples.count, 2)
        // First sample got closed at the second's start time (1060).
        XCTAssertEqual(samples[0].endedAt, 1060)
        XCTAssertNil(samples[1].endedAt)
    }

    func testPageTextDedupByHash() throws {
        let db = try AppDatabase.inMemory()
        let clock = FixedClock(Date(timeIntervalSince1970: 1000))
        let recorder = SampleRecorder(db: db, clock: clock)
        let id = try recorder.record(FrontmostContext(appBundleId: "com.google.Chrome", appName: "Chrome", isBrowser: true, url: "https://x.org/a"))

        XCTAssertTrue(try recorder.recordPageText(sampleId: id, url: "https://x.org/a", title: "A", rawText: "hello"))
        // Same text → skipped.
        XCTAssertFalse(try recorder.recordPageText(sampleId: id, url: "https://x.org/a", title: "A", rawText: "hello"))
        // Changed text → stored.
        XCTAssertTrue(try recorder.recordPageText(sampleId: id, url: "https://x.org/a", title: "A", rawText: "hello world"))

        let counts = try db.tableRowCounts()
        XCTAssertEqual(counts["page_snapshots"], 2)
    }
}

final class SessionBuildJobTests: XCTestCase {
    func testBuildsAndPersistsSessions() throws {
        let db = try AppDatabase.inMemory()
        let clock = FixedClock(Date(timeIntervalSince1970: 1000))
        let recorder = SampleRecorder(db: db, clock: clock)

        // Two Chrome samples on the same host, then a long gap, then Slack.
        let base: Int64 = 1000
        try db.insertSample(ActivitySample(startedAt: base, endedAt: base + 300, appBundleId: "com.google.Chrome", appName: "Chrome", isBrowser: true, url: "https://client.org/admin", source: "switch", createdAt: base))
        try db.insertSample(ActivitySample(startedAt: base + 300, endedAt: base + 600, appBundleId: "com.google.Chrome", appName: "Chrome", isBrowser: true, url: "https://client.org/admin", source: "switch", createdAt: base))
        try db.insertSample(ActivitySample(startedAt: base + 600, endedAt: base + 900, appBundleId: "com.tinyspeck.slackmacgap", appName: "Slack", source: "switch", createdAt: base))
        _ = recorder // silence unused

        let job = SessionBuildJob(sessionizer: Sessionizer(detourTolerance: 120, minSessionSeconds: 60), clock: clock)
        let written = try job.run(db, from: 0, to: 100_000, now: base + 900)
        XCTAssertEqual(written, 2)

        let sessions = try db.sessions(from: 0, to: 100_000)
        XCTAssertEqual(sessions.map(\.contextKey), ["web:client.org", "app:com.tinyspeck.slackmacgap"])
        XCTAssertEqual(sessions[0].durationSeconds, 600)
        XCTAssertEqual(sessions[0].kind, "screen")
    }

    func testOpenLastSampleUsesNowAsEnd() throws {
        let db = try AppDatabase.inMemory()
        let job = SessionBuildJob(sessionizer: Sessionizer(detourTolerance: 120, minSessionSeconds: 1))
        let samples = [ActivitySample(id: 1, startedAt: 1000, endedAt: nil, appBundleId: "com.a", appName: "A", source: "switch", createdAt: 1000)]
        let drafts = job.drafts(from: samples, now: 1500)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].end, 1500)
        XCTAssertEqual(drafts[0].durationSeconds, 500)
    }
}

final class RetentionTests: XCTestCase {
    func testPurgesOldSamplesAndCascadesSnapshots() throws {
        let db = try AppDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 100 * 86_400) // day 100
        let old: Int64 = Int64((5) * 86_400)    // day 5, 95 days old → strictly older than the 90d cutoff
        let recent: Int64 = Int64((99) * 86_400) // day 99

        let oldId = try db.insertSample(ActivitySample(startedAt: old, appBundleId: "com.a", appName: "A", source: "switch", createdAt: old))
        try db.insertPageSnapshot(PageSnapshot(sampleId: oldId, capturedAt: old, url: "u", contentHash: "h", text: "t", textBytes: 1))
        let recentId = try db.insertSample(ActivitySample(startedAt: recent, appBundleId: "com.b", appName: "B", source: "switch", createdAt: recent))
        _ = recentId

        let deleted = try RetentionJob().purge(db, retentionDays: ["activity_samples": 90, "page_snapshots": 90], now: now)
        XCTAssertEqual(deleted["activity_samples"], 1)

        let counts = try db.tableRowCounts()
        XCTAssertEqual(counts["activity_samples"], 1)      // only the recent one remains
        XCTAssertEqual(counts["page_snapshots"], 0)         // cascaded with the old sample
    }

    /// Slack sessions are derived from slack_messages, so they age out together. Screen sessions
    /// are primary capture and persist forever.
    func testSlackSessionsPurgeWithTheirMessages() throws {
        let db = try AppDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let old = Int64(5 * 86_400), recent = Int64(99 * 86_400)
        try db.insertSession(Session(kind: "slack", startedAt: old, endedAt: old + 60,
                                     durationSeconds: 60, sourceRef: "C1", createdAt: old))
        try db.insertSession(Session(kind: "screen", startedAt: old, endedAt: old + 60,
                                     durationSeconds: 60, createdAt: old))
        try db.insertSession(Session(kind: "slack", startedAt: recent, endedAt: recent + 60,
                                     durationSeconds: 60, sourceRef: "C2", createdAt: recent))
        let deleted = try RetentionJob().purge(db, retentionDays: ["slack_messages": 90], now: now)
        XCTAssertEqual(deleted["sessions(kind=slack)"], 1)
        let remaining = try db.sessions(from: 0, to: 200 * 86_400)
        XCTAssertEqual(remaining.count, 2)
        XCTAssertTrue(remaining.contains { $0.kind == "screen" }, "screen sessions persist forever")
        XCTAssertTrue(remaining.contains { $0.kind == "slack" && $0.startedAt == recent })
    }

    func testSkipsUnknownOrAbsentTables() throws {
        let db = try AppDatabase.inMemory()
        // A table with no configured timestamp column (and/or not present) is skipped silently.
        let deleted = try RetentionJob().purge(db, retentionDays: ["not_a_real_table": 90], now: Date())
        XCTAssertNil(deleted["not_a_real_table"])
    }

    func testPurgesSlackMessagesByPostedAt() throws {
        let db = try AppDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        try db.upsertSlackMessages([
            SlackMessage(conversationId: "C1", conversationType: "channel", ts: "1", postedAt: Int64(5 * 86_400), fetchedAt: 0),  // old
            SlackMessage(conversationId: "C1", conversationType: "channel", ts: "2", postedAt: Int64(99 * 86_400), fetchedAt: 0), // recent
        ])
        let deleted = try RetentionJob().purge(db, retentionDays: ["slack_messages": 90], now: now)
        XCTAssertEqual(deleted["slack_messages"], 1)
        XCTAssertEqual(try db.tableRowCounts()["slack_messages"], 1)
    }
}

final class SyncStateTests: XCTestCase {
    func testSyncStateRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        XCTAssertNil(try db.syncState("productive"))
        try db.saveSyncState(SyncState(source: "productive", cursor: "2026-07-01", lastRunAt: 1000))
        let s = try db.syncState("productive")
        XCTAssertEqual(s?.cursor, "2026-07-01")
        XCTAssertEqual(s?.lastRunAt, 1000)
    }
}

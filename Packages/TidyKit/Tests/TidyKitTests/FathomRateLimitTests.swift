import XCTest
import Foundation
import TidyCore
import TidyStore
import TidyIngest

/// Fathom 429-loop: 2,246 consecutive failures over 33 days with `meetings` at 0 and
/// `last_success_at` never once set.
///
/// The 90-day first-pull bound (43ca776) was already in the running build and did not help,
/// because the failure was structural: pages accumulated in memory, a 429 on any page threw the
/// whole lot away, and the cursor advanced only on a fully successful walk — so every run replayed
/// the identical page sequence into the identical limit.
final class FathomRateLimitTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func meeting(_ id: String, recordingStart: Int64) -> FathomMeetingBundle {
        FathomMeetingBundle(
            meeting: Meeting(
                id: id, source: "fathom", title: "Meeting \(id)",
                scheduledStart: recordingStart, scheduledEnd: recordingStart + 1800,
                recordingStart: recordingStart, recordingEnd: recordingStart + 1800,
                durationSeconds: 1800, fetchedAt: 0, createdAt: 0),
            invitees: [], utterances: [])
    }

    // MARK: The structural fix — progress survives a mid-pagination rate limit

    func testPagesAlreadyFetchedArePersistedWhenALaterPage429s() async throws {
        let db = try AppDatabase.inMemory()
        let client = FakeFathomClient(pages: [
            .success(FathomPage(bundles: [meeting("m1", recordingStart: 1_699_000_000)], nextCursor: "p2")),
            .success(FathomPage(bundles: [meeting("m2", recordingStart: 1_699_100_000)], nextCursor: "p3")),
            .failure(.rateLimited(provider: "fathom", attempts: 6, waitedSeconds: 95, detail: "…")),
        ])

        do {
            _ = try await FathomSync(client: client, db: db, clock: FixedClock(now)).run()
            XCTFail("the rate limit must still surface")
        } catch let IngestError.rateLimited(provider, _, _, _) {
            XCTAssertEqual(provider, "fathom")
        }

        // The whole point: the two pages fetched before the limit are banked, not discarded.
        XCTAssertEqual(try db.tableRowCounts()["meetings"], 2,
                       "pages fetched before the 429 must survive it")
    }

    /// …and the cursor advances, so the next run resumes instead of replaying the same pages.
    /// This is the property whose absence made the loop permanent.
    func testCursorAdvancesSoTheNextRunDoesNotReplay() async throws {
        let db = try AppDatabase.inMemory()
        let client = FakeFathomClient(pages: [
            .success(FathomPage(bundles: [meeting("m1", recordingStart: 1_699_000_000)], nextCursor: "p2")),
            .failure(.rateLimited(provider: "fathom", attempts: 6, waitedSeconds: 95, detail: "…")),
        ])
        _ = try? await FathomSync(client: client, db: db, clock: FixedClock(now)).run()

        let state = try db.syncState("fathom")
        let cursor = try XCTUnwrap(state?.cursor, "a partial run must still advance the cursor")
        let parsed = try XCTUnwrap(ISO8601DateFormatter().date(from: cursor))
        XCTAssertEqual(parsed.timeIntervalSince1970, 1_699_000_000, accuracy: 2)

        // A partial run is NOT a success — misreporting it would hide the problem.
        XCTAssertNil(state?.lastSuccessAt)

        // Next run picks up from the cursor rather than the 90-day fallback.
        let second = FakeFathomClient(bundles: [])
        _ = try await FathomSync(client: second, db: db, clock: FixedClock(now)).run()
        XCTAssertEqual(second.requestedCursors.count, 1)
    }

    func testCompleteWalkStampsSuccessAndClearsTheError() async throws {
        let db = try AppDatabase.inMemory()
        try db.saveSyncState(SyncState(source: "fathom", cursor: nil, lastRunAt: 1,
                                       lastSuccessAt: nil, lastError: "http 429: "))
        let client = FakeFathomClient(pages: [
            .success(FathomPage(bundles: [meeting("m1", recordingStart: 1_699_000_000)], nextCursor: "p2")),
            .success(FathomPage(bundles: [meeting("m2", recordingStart: 1_699_100_000)], nextCursor: nil)),
        ])

        let total = try await FathomSync(client: client, db: db, clock: FixedClock(now)).run()

        XCTAssertEqual(total, 2)
        let state = try db.syncState("fathom")
        XCTAssertNotNil(state?.lastSuccessAt)
        XCTAssertNil(state?.lastError, "a clean walk clears the stale error")
    }

    /// An empty-string cursor (what the live DB actually held) must not be mistaken for a real one
    /// and sent as `created_after=`.
    func testEmptyCursorFallsBackToTheNinetyDayWindow() async throws {
        let db = try AppDatabase.inMemory()
        try db.saveSyncState(SyncState(source: "fathom", cursor: "", lastRunAt: 1))
        let client = FakeFathomClient(bundles: [])
        _ = try await FathomSync(client: client, db: db, clock: FixedClock(now)).run()
        XCTAssertEqual(client.requestedCursors, [nil])
    }

    // MARK: Retry budget

    /// The old default slept 0.5 + 1 + 2 = 3.5s total against a rolling 60-second window — about
    /// 17x short, and against what docs/reference/fathom-api.md already prescribed.
    func testRetryBudgetCanOutlastASixtySecondWindow() {
        let old = Backoff(base: 0.5, cap: 30)
        XCTAssertEqual(old.totalDelay(retries: 3), 3.5, accuracy: 0.01)
        XCTAssertLessThan(old.totalDelay(retries: 3), 60, "the old budget could not clear the window")

        let now = Backoff(base: 5, cap: 30)
        XCTAssertEqual(now.totalDelay(retries: 5), 95, accuracy: 0.01)
        XCTAssertGreaterThan(now.totalDelay(retries: 5), 60, "must be able to outlast a 60s window")
    }

    // MARK: Header casing — the silently-dead backoff

    /// HTTP/2 lowercases header names on the wire, and the clients subscripted the exact literal
    /// `"Retry-After"` in a case-sensitive dictionary. Every server-directed backoff was therefore
    /// silently ignored in production while the code looked correct.
    func testServerRequestedDelayIsCaseInsensitive() {
        XCTAssertEqual(HTTPResponse(status: 429, headers: ["retry-after": "42"]).serverRequestedDelay, 42)
        XCTAssertEqual(HTTPResponse(status: 429, headers: ["Retry-After": "42"]).serverRequestedDelay, 42)
        XCTAssertEqual(HTTPResponse(status: 429, headers: ["RETRY-AFTER": "42"]).serverRequestedDelay, 42)
    }

    /// Fathom sends no `Retry-After` at all — it advertises the IETF `RateLimit-*` family.
    /// Verified against a live api.fathom.ai response on 2026-08-28.
    func testRateLimitResetIsHonouredWhenRetryAfterIsAbsent() {
        let fathomLike = HTTPResponse(status: 429, headers: [
            "ratelimit-limit": "60", "ratelimit-remaining": "0", "ratelimit-reset": "37",
        ])
        XCTAssertEqual(fathomLike.serverRequestedDelay, 37)

        // reset:0 means the window already rolled — that is no guidance, not "retry instantly".
        let rolled = HTTPResponse(status: 429, headers: ["ratelimit-reset": "0"])
        XCTAssertNil(rolled.serverRequestedDelay)
        XCTAssertNil(HTTPResponse(status: 429).serverRequestedDelay)
    }

    // MARK: The error a human has to act on

    func testExhaustedRetriesExplainItselfInsteadOfSayingHttp429() async throws {
        let http = FakeHTTPClient([
            .json("", status: 429), .json("", status: 429), .json("", status: 429),
            .json("", status: 429), .json("", status: 429), .json("", status: 429),
        ])
        let client = LiveFathomClient(http: http, apiKey: "k", sleeper: { _ in })
        do {
            _ = try await client.fetchMeetingsPage(createdAfter: nil, cursor: nil)
            XCTFail("expected a rate-limit error")
        } catch let error as IngestError {
            let text = error.description
            XCTAssertNotEqual(text, "http 429: ", "the uninformative old message")
            XCTAssertTrue(text.contains("fathom rate limit"))
            XCTAssertTrue(text.contains("attempts"))
            XCTAssertTrue(text.contains("API Access"), "must name the thing a human can check")
            XCTAssertTrue(text.contains("resumes"), "must say partial progress was kept")
        }
    }
}

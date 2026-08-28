import XCTest
import Foundation
import TidyCore
import TidyStore
import TidySurface
@testable import TidyIngest

/// Regression tests from the round-3 review (2026-07-27): each fixed finding gets a guard, and the
/// three previously-untested first-live-run fixes get their missing coverage.

// R2-1: the Slack 429 backoff — the fix for the live run's headline failure — had no test.
final class SlackBackoffTests: XCTestCase {
    func testRetriesOn429HonoringRetryAfter() async throws {
        let http = FakeHTTPClient([
            .json("{}", status: 429, headers: ["Retry-After": "0"]),
            .json(#"{"ok":true,"user_id":"ME"}"#),
        ])
        let client = LiveSlackClient(http: http, token: "xoxp-t", sleeper: { _ in })
        let uid = try await client.authTestUserId()
        XCTAssertEqual(uid, "ME")
        XCTAssertEqual(http.sentRequests.count, 2, "must retry after a 429")
    }

    func testGivesUpAfterMaxRetries() async throws {
        let http = FakeHTTPClient([
            .json("{}", status: 429), .json("{}", status: 429),
            .json("{}", status: 429), .json("{}", status: 429),
        ])
        let client = LiveSlackClient(http: http, token: "t", maxRetries: 3, sleeper: { _ in })
        do {
            _ = try await client.authTestUserId()
            XCTFail("expected http 429 after retries exhausted")
        } catch let IngestError.http(status, _) {
            XCTAssertEqual(status, 429)
        }
        XCTAssertEqual(http.sentRequests.count, 4)   // initial + 3 retries
    }
}

// R2-2: the users.list daily throttle was untested and unobservable.
final class SlackUsersThrottleTests: XCTestCase {
    func testUserNamesFetchedOncePerDayAndBackfilled() async throws {
        let db = try AppDatabase.inMemory()
        let clock = FixedClock(Date(timeIntervalSince1970: 100_000))
        let client = CountingSlackClient(
            selfUserId: "ME", names: ["ME": "Bryan", "OTHER": "Nick"],
            conversations: [SlackConversation(id: "C1", name: "x", type: "channel")],
            messages: ["C1": [SlackMessageDTO(userId: "OTHER", text: "hi", ts: "99000.0"),
                             SlackMessageDTO(userId: "ME", text: "yo", ts: "99001.0")]])
        let sync = SlackSync(client: client, db: db, clock: clock)

        _ = try await sync.run()
        XCTAssertEqual(client.userNamesCalls, 1)

        clock.advance(by: 3600)          // 1h later — throttled
        _ = try await sync.run()
        XCTAssertEqual(client.userNamesCalls, 1, "users.list must be throttled to daily")

        clock.advance(by: 86_400)        // past 24h — refreshed
        _ = try await sync.run()
        XCTAssertEqual(client.userNamesCalls, 2)
    }

    // R1-C2: messages stored during the throttle window must get names on the next refresh.
    func testBackfillNamesMessagesStoredDuringThrottle() async throws {
        let db = try AppDatabase.inMemory()
        // Simulate the throttle window: a message stored with no name.
        try db.upsertSlackMessages([SlackMessage(conversationId: "C1", conversationType: "channel",
                                                 ts: "50.0", postedAt: 50, userId: "U9",
                                                 userName: nil, fetchedAt: 1)])
        try db.backfillSlackUserNames(["U9": "Dana"])
        XCTAssertEqual(try db.slackMessages(conversationId: "C1").first?.userName, "Dana")
        // And names never overwrite an existing value.
        try db.backfillSlackUserNames(["U9": "Wrong"])
        XCTAssertEqual(try db.slackMessages(conversationId: "C1").first?.userName, "Dana")
    }
}

/// FakeSlackClient with a userNames() call counter (round-3 R2-2 seam).
final class CountingSlackClient: SlackClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var userNamesCalls = 0
    let selfUserId: String
    let names: [String: String]
    let conversations: [SlackConversation]
    let messages: [String: [SlackMessageDTO]]

    init(selfUserId: String, names: [String: String], conversations: [SlackConversation],
         messages: [String: [SlackMessageDTO]]) {
        self.selfUserId = selfUserId; self.names = names
        self.conversations = conversations; self.messages = messages
    }

    func authTestUserId() async throws -> String { selfUserId }
    func userNames() async throws -> [String: String] {
        lock.withLock { userNamesCalls += 1 }
        return names
    }
    func listConversations() async throws -> [SlackConversation] { conversations }
    func history(conversationId: String, oldestTs: String?) async throws -> [SlackMessageDTO] {
        let all = messages[conversationId] ?? []
        guard let oldestTs, let cutoff = Double(oldestTs) else { return all }
        return all.filter { (Double($0.ts) ?? 0) > cutoff }
    }
}

// R2-3: Fathom's bounded first pull was untested and unobservable.
final class FathomFirstSyncBoundTests: XCTestCase {
    final class CapturingFathomClient: FathomClient, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var receivedCreatedAfter: [String?] = []
        func fetchMeetingsPage(createdAfter: String?, cursor: String?) async throws -> FathomPage {
            lock.withLock { receivedCreatedAfter.append(createdAfter) }
            return FathomPage(bundles: [], nextCursor: nil)
        }
    }

    func testNoCursorUsesNinetyDayFallback() async throws {
        let db = try AppDatabase.inMemory()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let client = CapturingFathomClient()
        _ = try await FathomSync(client: client, db: db, clock: clock).run()
        let received = client.receivedCreatedAfter.first ?? nil
        XCTAssertNotNil(received, "first sync must be bounded, not all-history")
        let parsed = ISO8601DateFormatter().date(from: received!)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.timeIntervalSince1970, 1_700_000_000 - 90 * 86_400, accuracy: 2)
    }

    func testExistingCursorWins() async throws {
        let db = try AppDatabase.inMemory()
        try db.saveSyncState(SyncState(source: "fathom", cursor: "2026-07-01T00:00:00Z"))
        let client = CapturingFathomClient()
        _ = try await FathomSync(client: client, db: db,
                                 clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_000))).run()
        XCTAssertEqual(client.receivedCreatedAfter.first ?? nil, "2026-07-01T00:00:00Z")
    }
}

// R2-5: run(.googleCalendar) had only its failure path tested.
final class GoogleHappyPathSyncTests: XCTestCase {
    func testFullyConfiguredGoogleSyncStoresEventsAndCursor() async throws {
        let db = try AppDatabase.inMemory()
        var config = Config()
        config.google.clientId = "cid"
        let secrets = InMemorySecretStore([SecretKey.googleClientSecret: "s",
                                           SecretKey.googleRefreshToken: "rt"])
        let events = """
        { "items": [ { "id":"ev1","status":"confirmed","summary":"Standup",
            "start":{"dateTime":"2026-07-27T15:00:00Z"},"end":{"dateTime":"2026-07-27T15:30:00Z"} } ],
          "nextSyncToken":"tok-1" }
        """
        let http = FakeHTTPClient([
            .json(#"{"access_token":"at","expires_in":3600}"#),   // token refresh
            .json(events),                                         // events.list
        ])
        let c = IngestCoordinator(db: db, config: config, secrets: secrets, http: http,
                                  clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_000)))
        await c.runAll()
        XCTAssertEqual(try db.calendarEvents(from: 0, to: .max).count, 1)
        XCTAssertEqual(((try db.syncState("google_calendar")) ?? nil)?.cursor, "tok-1")
        XCTAssertNil(((try db.syncState("google_calendar")) ?? nil)?.lastError)
        // First sync must have carried a bounded window.
        let eventsRequest = http.sentRequests[1].url.absoluteString
        XCTAssertTrue(eventsRequest.contains("timeMin"), "first sync must be windowed")
    }
}

// R2-4: signInWithGoogle guards (via the test init — no browser, no network).
@MainActor
final class SignInGuardTests: XCTestCase {
    private func makeEnv() throws -> AppEnvironment {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tt-signin-\(UUID().uuidString)", isDirectory: true)
        return AppEnvironment(db: try AppDatabase.inMemory(), config: Config(),
                              paths: AppPaths(supportDirectory: dir))
    }

    func testMissingClientIdFailsFastWithActionableMessage() throws {
        let env = try makeEnv()
        env.signInWithGoogle()
        guard case .failed(let message) = env.googleSignIn else {
            return XCTFail("expected fast failure, got \(env.googleSignIn)")
        }
        XCTAssertTrue(message.contains("client_id"))
    }
}

// R3-2: sync_state.last_error must never carry a secret.
final class LastErrorRedactionTests: XCTestCase {
    func testIngestFailureErrorIsRedactedBeforePersisting() async throws {
        let db = try AppDatabase.inMemory()
        var config = Config()
        config.google.clientId = "cid"
        let secretValue = "super-secret-refresh-token-value"
        let secrets = InMemorySecretStore([SecretKey.googleClientSecret: "cs-value",
                                           SecretKey.googleRefreshToken: secretValue])
        // Google's error body echoes the refresh token (worst case) — it must not reach the DB.
        let http = FakeHTTPClient([
            .json("{\"error\":\"invalid_grant\",\"error_description\":\"bad token \(secretValue)\"}",
                  status: 400),
        ])
        let c = IngestCoordinator(db: db, config: config, secrets: secrets, http: http,
                                  clock: FixedClock(Date(timeIntervalSince1970: 1)))
        await c.runAll()
        let lastError = ((try db.syncState("google_calendar")) ?? nil)?.lastError ?? ""
        XCTAssertFalse(lastError.isEmpty)
        XCTAssertFalse(lastError.contains(secretValue), "secret leaked into sync_state.last_error")
        XCTAssertTrue(lastError.contains(Redactor.mask))
    }
}

// R1-C7: an expired Google syncToken (410) must reset the cursor and recover, not fail forever.
final class SyncTokenExpiryTests: XCTestCase {
    func testExpiredSyncTokenResetsCursorAndRetries() async throws {
        let db = try AppDatabase.inMemory()
        try db.saveSyncState(SyncState(source: "google_calendar", cursor: "stale-token"))
        var config = Config()
        config.google.clientId = "cid"
        let secrets = InMemorySecretStore([SecretKey.googleClientSecret: "s",
                                           SecretKey.googleRefreshToken: "rt"])
        let http = FakeHTTPClient([
            .json(#"{"access_token":"at","expires_in":3600}"#),   // token refresh
            .json("gone", status: 410),                            // stale cursor rejected
            .json(#"{"items":[],"nextSyncToken":"fresh-tok"}"#),   // full re-fetch succeeds
        ])
        let c = IngestCoordinator(db: db, config: config, secrets: secrets, http: http,
                                  clock: FixedClock(Date(timeIntervalSince1970: 1)))
        await c.runAll()
        XCTAssertEqual(((try db.syncState("google_calendar")) ?? nil)?.cursor, "fresh-tok")
        XCTAssertNil(((try db.syncState("google_calendar")) ?? nil)?.lastError)
    }
}

// R2-6: the CLI's snapshot parsing round-trips against real bundle output.
final class SnapshotReaderTests: XCTestCase {
    func testPermissionsRoundTripThroughARenderedBundle() {
        let input = DiagnosticsInput(
            appVersion: "1", osVersion: "os", deviceModel: "m",
            generatedAt: Date(timeIntervalSince1970: 0),
            permissions: ["Accessibility": "granted",
                          "Code signature": "stable (team X, id: com.4site.TidyTime)",
                          "Notifications": "not determined"])
        let rendered = DiagnosticsBundle.render(input)
        let parsed = DiagnosticsAssembler.permissions(fromSnapshot: rendered)
        XCTAssertEqual(parsed["Accessibility"], "granted")
        XCTAssertEqual(parsed["Code signature"], "stable (team X, id: com.4site.TidyTime)")
        XCTAssertEqual(parsed["Notifications"], "not determined")
        XCTAssertNil(parsed["Database"], "non-permission lines must not leak in")
    }
}

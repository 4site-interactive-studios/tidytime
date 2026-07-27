import XCTest
import Foundation
import TidyCore
import TidyStore
@testable import TidyIngest

final class SlackMigrationAndStoreTests: XCTestCase {
    func testV1SlackMigration() throws {
        let db = try AppDatabase.inMemory()
        XCTAssertTrue(try db.appliedMigrations().contains("v1-slack"))
        XCTAssertNotNil(try db.tableRowCounts()["slack_messages"])
    }

    func testUpsertIdempotentOnConversationAndTs() throws {
        let db = try AppDatabase.inMemory()
        let msg = SlackMessage(conversationId: "C1", conversationType: "channel", ts: "100.0001",
                               postedAt: 100, userId: "U1", text: "hi", fetchedAt: 1)
        try db.upsertSlackMessages([msg])
        try db.upsertSlackMessages([msg])  // same conv+ts → replace, not duplicate
        XCTAssertEqual(try db.tableRowCounts()["slack_messages"], 1)
    }

    func testLatestTsCursor() throws {
        let db = try AppDatabase.inMemory()
        try db.upsertSlackMessages([
            SlackMessage(conversationId: "C1", conversationType: "channel", ts: "100.0", postedAt: 100, fetchedAt: 1),
            SlackMessage(conversationId: "C1", conversationType: "channel", ts: "200.0", postedAt: 200, fetchedAt: 1),
        ])
        XCTAssertEqual(try db.latestSlackTs(conversationId: "C1"), "200.0")
    }
}

final class SlackTSTests: XCTestCase {
    func testTsToEpoch() {
        XCTAssertEqual(SlackTS.epoch("1719000000.001200"), 1_719_000_000)
    }
}

final class SlackSessionizerTests: XCTestCase {
    private func msg(_ ts: Int64, mine: Bool = true) -> SlackMessage {
        SlackMessage(conversationId: "C1", conversationType: "channel", ts: "\(ts).0", postedAt: ts,
                     isSelf: mine, fetchedAt: 0)
    }

    /// Colleagues chatting in a channel is NOT the user's time. The first live sync built 12k
    /// phantom sessions out of exactly this.
    func testColleagueOnlyMessagesCreateNoSessions() {
        let s = SlackSessionizer(gapSeconds: 900, nominalSeconds: 60)
        let sessions = s.sessions(conversationId: "C1", name: "general",
                                  messages: [msg(1000, mine: false), msg(1100, mine: false)], createdAt: 0)
        XCTAssertTrue(sessions.isEmpty)
    }

    func testMixedThreadAnchorsOnOwnMessagesOnly() {
        let s = SlackSessionizer(gapSeconds: 900, nominalSeconds: 60)
        let sessions = s.sessions(conversationId: "C1", name: "help",
                                  messages: [msg(1000, mine: false), msg(1200, mine: true),
                                             msg(1300, mine: false), msg(5000, mine: false)], createdAt: 0)
        XCTAssertEqual(sessions.count, 1)               // one cluster, from the single own message
        XCTAssertEqual(sessions[0].startedAt, 1200)
    }

    func testSplitsOnGap() {
        let s = SlackSessionizer(gapSeconds: 900, nominalSeconds: 60)
        // three messages close together, then a >15min gap, then one more
        let sessions = s.sessions(conversationId: "C1", name: "acme",
                                  messages: [msg(1000), msg(1100), msg(1200), msg(5000)], createdAt: 0)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].startedAt, 1000)
        XCTAssertEqual(sessions[0].endedAt, 1200)
        XCTAssertEqual(sessions[0].contextKey, "slack:C1")
        // single-message cluster gets a nominal duration
        XCTAssertEqual(sessions[1].durationSeconds, 60)
    }
}

final class SlackFirstSyncBoundTests: XCTestCase {
    /// No cursor used to mean "pull everything since 2014". Now the first pull is bounded.
    func testFirstSyncSkipsMessagesOlderThanTheWindow() async throws {
        let db = try AppDatabase.inMemory()
        let now: Int64 = 100 * 86_400                       // day 100
        let old: Int64 = 10 * 86_400                        // day 10 — far outside a 30d window
        let recent: Int64 = 99 * 86_400                     // day 99
        let client = FakeSlackClient(
            selfUserId: "ME",
            conversations: [SlackConversation(id: "C1", name: "x", type: "channel")],
            messagesByConversation: ["C1": [
                SlackMessageDTO(userId: "ME", text: "ancient", ts: "\(old).000100"),
                SlackMessageDTO(userId: "ME", text: "fresh", ts: "\(recent).000100"),
            ]])
        let sync = SlackSync(client: client, db: db,
                             clock: FixedClock(Date(timeIntervalSince1970: TimeInterval(now))),
                             initialHistoryDays: 30)
        _ = try await sync.run()
        let stored = try db.slackMessages(conversationId: "C1")
        XCTAssertEqual(stored.count, 1, "the pre-window message must not be ingested")
        XCTAssertEqual(stored.first?.text, "fresh")
    }
}

final class SlackSyncTests: XCTestCase {
    func testSyncUpsertsMessagesAndBuildsSessions() async throws {
        let db = try AppDatabase.inMemory()
        let client = FakeSlackClient(
            selfUserId: "ME",
            names: ["ME": "Bryan", "OTHER": "Nick"],
            conversations: [SlackConversation(id: "C1", name: "acme-project", type: "channel")],
            messagesByConversation: [
                "C1": [
                    SlackMessageDTO(userId: "OTHER", text: "can you check the selector?", ts: "1000.0"),
                    SlackMessageDTO(userId: "ME", text: "on it", ts: "1030.0"),
                ]
            ])
        let sync = SlackSync(client: client, db: db, clock: FixedClock(Date(timeIntervalSince1970: 9999)))
        let count = try await sync.run()
        XCTAssertEqual(count, 2)

        let messages = try db.slackMessages(conversationId: "C1")
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages.first { $0.userId == "ME" }?.isSelf ?? false)
        XCTAssertEqual(messages.first { $0.userId == "OTHER" }?.userName, "Nick")

        let sessions = try db.sessions(from: 0, to: 100_000)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].kind, "slack")
        XCTAssertEqual(sessions[0].sourceRef, "C1")

        // cursor advanced
        XCTAssertEqual(try db.syncState("slack:C1")?.cursor, "1030.0")

        // Re-sync (only newer messages returned) must not duplicate sessions.
        _ = try await sync.run()
        XCTAssertEqual(try db.sessions(from: 0, to: 100_000).count, 1)
        XCTAssertEqual(try db.slackMessages(conversationId: "C1").count, 2)
    }

    func testParsesLiveConversationTypes() async throws {
        let listJSON = """
        { "ok": true, "channels": [
            {"id":"C1","name":"general","is_channel":true},
            {"id":"D1","is_im":true},
            {"id":"G1","is_mpim":true}
        ], "response_metadata": {"next_cursor": ""} }
        """
        let http = FakeHTTPClient([.json(listJSON)])
        let client = LiveSlackClient(http: http, token: "xoxp-test")
        let convs = try await client.listConversations()
        XCTAssertEqual(convs.map(\.type), ["channel", "im", "mpim"])
        XCTAssertEqual(http.sentRequests[0].headers["Authorization"], "Bearer xoxp-test")
    }

    func testLiveClientSurfacesSlackError() async throws {
        let http = FakeHTTPClient([.json(#"{"ok":false,"error":"not_authed"}"#)])
        let client = LiveSlackClient(http: http, token: "bad")
        do {
            _ = try await client.authTestUserId()
            XCTFail("expected error")
        } catch let IngestError.transport(msg) {
            XCTAssertTrue(msg.contains("not_authed"))
        }
    }
}

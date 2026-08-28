import XCTest
import Foundation
import TidyCore
import TidyStore
import TidyIngest

/// One unreachable conversation must not take down the whole Slack source.
///
/// The live symptom: every sync failed with `channel_not_found` on `C07C12FMTEF`, and
/// `sync_state('slack').last_success_at` had never once been set — despite 7,309 messages banked
/// across 120 conversations. The run reached the dead channel and unwound.
final class SlackUnreachableTests: XCTestCase {
    private let day: Int64 = 1_700_000_000

    private func makeClient(errors: [String: String]) -> FakeSlackClient {
        FakeSlackClient(
            selfUserId: "U1",
            names: ["U1": "Bryan"],
            conversations: [
                SlackConversation(id: "C_OK1", name: "general", type: "channel"),
                SlackConversation(id: "C07C12FMTEF", name: "dead", type: "channel"),
                SlackConversation(id: "C_OK2", name: "after-the-dead-one", type: "channel"),
            ],
            messagesByConversation: [
                "C_OK1": [SlackMessageDTO(userId: "U1", text: "before", ts: "\(day - 100).000100")],
                "C_OK2": [SlackMessageDTO(userId: "U1", text: "after", ts: "\(day - 50).000100")],
            ],
            historyErrors: errors)
    }

    /// The headline behaviour: conversations ordered *after* the dead one still sync.
    func testOneDeadChannelDoesNotAbortTheRun() async throws {
        let db = try AppDatabase.inMemory()
        let client = makeClient(errors: ["C07C12FMTEF": "channel_not_found"])
        let sync = SlackSync(client: client, db: db, clock: FixedClock(Date(timeIntervalSince1970: TimeInterval(day))))

        let total = try await sync.run()

        XCTAssertEqual(total, 2, "both healthy conversations must bank their messages")
        XCTAssertEqual(try db.slackMessages(conversationId: "C_OK1").count, 1)
        XCTAssertEqual(try db.slackMessages(conversationId: "C_OK2").count, 1,
                       "the conversation AFTER the dead one is the one the old code never reached")
    }

    /// The dead conversation is recorded, so it stops being polled every 15 minutes.
    func testUnreachableConversationIsPersistedAndThenSkipped() async throws {
        let db = try AppDatabase.inMemory()
        let client = makeClient(errors: ["C07C12FMTEF": "channel_not_found"])
        let clock = FixedClock(Date(timeIntervalSince1970: TimeInterval(day)))

        try await SlackSync(client: client, db: db, clock: clock).run()
        let state = try db.syncState("slack:C07C12FMTEF")
        XCTAssertNotNil(state?.lastError)
        XCTAssertTrue(state?.lastError?.contains("channel_not_found") == true)
        XCTAssertEqual(client.historyRequests.filter { $0 == "C07C12FMTEF" }.count, 1)

        // A second pass 15 minutes later must not ask for it again.
        let later = FixedClock(Date(timeIntervalSince1970: TimeInterval(day + 900)))
        try await SlackSync(client: client, db: db, clock: later).run()
        XCTAssertEqual(client.historyRequests.filter { $0 == "C07C12FMTEF" }.count, 1,
                       "a known-unreachable conversation must not be re-requested every cycle")
        // …while the healthy ones keep syncing.
        XCTAssertEqual(client.historyRequests.filter { $0 == "C_OK2" }.count, 2)
    }

    /// Skipping is a cooldown, not a tombstone. Slack documents that conversation IDs are not
    /// stable, and a rejoined channel must heal without the user knowing this state exists.
    func testUnreachableConversationIsReprobedAfterTheCooldown() async throws {
        let db = try AppDatabase.inMemory()
        let client = makeClient(errors: ["C07C12FMTEF": "channel_not_found"])

        try await SlackSync(client: client, db: db,
                            clock: FixedClock(Date(timeIntervalSince1970: TimeInterval(day)))).run()
        XCTAssertEqual(client.historyRequests.filter { $0 == "C07C12FMTEF" }.count, 1)

        // Access restored, and a day has passed.
        client.historyErrors = [:]
        client.messagesByConversation["C07C12FMTEF"] =
            [SlackMessageDTO(userId: "U1", text: "im back", ts: "\(day + 86_500).000100")]
        try await SlackSync(client: client, db: db,
                            clock: FixedClock(Date(timeIntervalSince1970: TimeInterval(day + 86_500)))).run()

        XCTAssertEqual(client.historyRequests.filter { $0 == "C07C12FMTEF" }.count, 2,
                       "the cooldown must expire so a rejoined channel recovers on its own")
        XCTAssertEqual(try db.slackMessages(conversationId: "C07C12FMTEF").count, 1)
        XCTAssertNil(try db.syncState("slack:C07C12FMTEF")?.lastError,
                     "a successful pass clears the unreachable marker")
    }

    /// `channel_not_found` is not the only code in this class — the question the fix had to answer.
    func testNotInChannelAndIsArchivedSkipToo() async throws {
        for code in ["not_in_channel", "is_archived", "channel_is_limited_access", "access_denied"] {
            let db = try AppDatabase.inMemory()
            let client = makeClient(errors: ["C07C12FMTEF": code])
            let total = try await SlackSync(
                client: client, db: db,
                clock: FixedClock(Date(timeIntervalSince1970: TimeInterval(day)))).run()
            XCTAssertEqual(total, 2, "\(code) is per-conversation and must not abort the run")
        }
    }

    /// A dead token is NOT a per-conversation problem. Continuing would burn quota against a token
    /// that fails identically on every call, and bury the real cause.
    func testTokenFailuresStillAbortTheWholeRun() async throws {
        for code in ["invalid_auth", "token_revoked", "missing_scope", "account_inactive"] {
            let db = try AppDatabase.inMemory()
            let client = makeClient(errors: ["C07C12FMTEF": code])
            do {
                _ = try await SlackSync(
                    client: client, db: db,
                    clock: FixedClock(Date(timeIntervalSince1970: TimeInterval(day)))).run()
                XCTFail("\(code) must abort the run, not be skipped")
            } catch let IngestError.slack(thrown, _) {
                XCTAssertEqual(thrown, code)
            }
        }
    }

    /// Rate limiting must never be mistaken for a dead channel: skipping would silently drop real
    /// messages and leave the cursor wrong.
    func testRateLimitIsNotTreatedAsUnreachable() async throws {
        let db = try AppDatabase.inMemory()
        let client = makeClient(errors: ["C07C12FMTEF": "ratelimited"])
        do {
            _ = try await SlackSync(client: client, db: db,
                                    clock: FixedClock(Date(timeIntervalSince1970: TimeInterval(day)))).run()
            XCTFail("ratelimited must propagate so the run retries with backoff")
        } catch let IngestError.slack(code, _) {
            XCTAssertEqual(code, "ratelimited")
        }
        XCTAssertNil(try db.syncState("slack:C07C12FMTEF")?.lastError,
                     "a throttled conversation must not be marked unreachable")
    }

    /// An unrecognized code fails closed. Silently skipping conversations on an unknown error is
    /// how a sync goes quietly and permanently empty.
    func testUnknownCodeIsFatalNotSkipped() {
        XCTAssertEqual(SlackErrorClass.classify("some_new_code_slack_invented"), .fatal)
        XCTAssertEqual(SlackErrorClass.classify("channel_not_found"), .skipConversation)
        XCTAssertEqual(SlackErrorClass.classify("ratelimited"), .retry)
        XCTAssertEqual(SlackErrorClass.classify("invalid_auth"), .fatal)
    }

    /// `conversation_not_found` does not exist in Slack's API — `channel_not_found` covers DMs and
    /// MPIMs too. Guards against a plausible-looking branch being added for a phantom code.
    func testNoBranchForTheNonexistentConversationNotFoundCode() {
        XCTAssertFalse(SlackErrorClass.skippable.contains("conversation_not_found"))
    }
}

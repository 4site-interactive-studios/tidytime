import XCTest
import Foundation
import TidyCore
import TidyStore
import TidyAI

final class NudgeEngineTests: XCTestCase {
    private func base() -> NudgeEngine {
        NudgeEngine(enabled: true, sustainedBlockSeconds: 25 * 60, confidenceThreshold: 0.7,
                    dailyCap: 5, quietStartMinute: 18 * 60, quietEndMinute: 9 * 60, maxDismissalsBeforeMute: 3)
    }
    private func input(confidence: Double = 0.9, sustained: Int = 30 * 60, meeting: Bool = false,
                       logged: Bool = false, firedToday: Int = 0, dismissals: Int = 0, minute: Int = 14 * 60) -> NudgeEngine.Input {
        .init(confidence: confidence, sustainedSeconds: sustained, isInMeeting: meeting,
              alreadyLoggedForContext: logged, nudgesFiredToday: firedToday, dismissalsForContext: dismissals, minuteOfDay: minute)
    }

    func testFiresWhenSustainedConfidentUnlogged() {
        XCTAssertTrue(base().decide(input()).shouldFire)
    }
    func testSuppressedInMeeting() {
        XCTAssertFalse(base().decide(input(meeting: true)).shouldFire)
    }
    func testSuppressedDuringQuietHours() {
        XCTAssertFalse(base().decide(input(minute: 20 * 60)).shouldFire)   // 20:00 within 18:00–09:00
    }
    func testSuppressedByDailyCap() {
        XCTAssertFalse(base().decide(input(firedToday: 5)).shouldFire)
    }
    func testSuppressedWhenNotSustained() {
        XCTAssertFalse(base().decide(input(sustained: 10 * 60)).shouldFire)
    }
    func testSuppressedWhenAlreadyLogged() {
        XCTAssertFalse(base().decide(input(logged: true)).shouldFire)
    }
    func testDismissalsRaiseThresholdThenMute() {
        // one dismissal → threshold 0.8; confidence 0.75 now fails
        XCTAssertFalse(base().decide(input(confidence: 0.75, dismissals: 1)).shouldFire)
        // still fires at higher confidence
        XCTAssertTrue(base().decide(input(confidence: 0.95, dismissals: 1)).shouldFire)
        // three dismissals → muted regardless of confidence
        XCTAssertFalse(base().decide(input(confidence: 0.99, dismissals: 3)).shouldFire)
    }

    func testQuietHoursWrapParsing() {
        XCTAssertEqual(NudgeEngine.minuteOfDay("09:30"), 570)
        XCTAssertNil(NudgeEngine.minuteOfDay("bad"))
        XCTAssertTrue(NudgeEngine.inWindow(23 * 60, 18 * 60, 9 * 60))   // 23:00 in 18:00–09:00
        XCTAssertFalse(NudgeEngine.inWindow(12 * 60, 18 * 60, 9 * 60))  // noon not in quiet
    }
}

final class NudgeStoreTests: XCTestCase {
    func testNudgeCountAndDismissals() throws {
        let db = try AppDatabase.inMemory()
        let id = try db.insertNudge(NudgeRecord(firedAt: 100, contextKey: "web:acme.org"))
        _ = try db.insertNudge(NudgeRecord(firedAt: 200, contextKey: "web:acme.org"))
        XCTAssertEqual(try db.nudgeCount(from: 0, to: 1000), 2)
        try db.setNudgeOutcome(id: id, outcome: "dismissed", now: 300)
        XCTAssertEqual(try db.nudgeDismissals(contextKey: "web:acme.org"), 1)
    }
}

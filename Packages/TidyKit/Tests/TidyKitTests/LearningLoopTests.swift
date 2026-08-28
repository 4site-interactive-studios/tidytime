import XCTest
import Foundation
import TidyCore
import TidyStore
import TidySuggest
import TidyUnderstand
import TidySurface

/// Stage 5: the recap has to teach the system, and something has to open it.
///
/// `RecapWindow` wrote its two rows by hand, skipping `DecisionRecorder` — the only thing that
/// writes a `user_confirmed` signal. So accepting a suggestion taught the app nothing and accuracy
/// could never improve with use, even though `RecapView`'s own doc comment claimed otherwise.
final class LearningLoopTests: XCTestCase {

    // MARK: Accepting a suggestion promotes the signal behind it

    func testAcceptingConfirmsTheContextKeySignal() throws {
        let db = try AppDatabase.inMemory()
        var s = Session(kind: "screen", startedAt: 100, endedAt: 200, durationSeconds: 100,
                        title: "work", contextKey: "web:acme.org", createdAt: 0)
        s.clientId = "c1"
        let sessionId = try db.insertSession(s)

        let suggestion = Suggestion(day: "2026-08-28", kind: "session", clientId: "c1",
                                    minutes: 60, rawSeconds: 3600, confidence: 0.8,
                                    producedByRung: 2,
                                    sourceRefsJson: "{\"sessions\":[\(sessionId)]}",
                                    createdAt: 0, updatedAt: 0)
        let ref = try XCTUnwrap(RecapWindow.signalToConfirm(db: db, suggestion: suggestion))
        XCTAssertEqual(ref.type, "url_host")
        XCTAssertEqual(ref.value, "acme.org", "the durable thing is the host, not this one card")

        // And recording it with that ref writes a user_confirmed signal.
        try DecisionRecorder(db: db, clock: FixedClock(Date(timeIntervalSince1970: 500)))
            .record(suggestionId: nil, action: "log", clientId: "c1", confirmSignal: ref)
        let signal = try XCTUnwrap(try db.signals(values: ["acme.org"]).first)
        XCTAssertEqual(signal.provenance, "user_confirmed",
                       "user rules outrank bootstrapped and inferred forever")
        XCTAssertEqual(signal.clientId, "c1")
    }

    /// A Slack conversation is equally durable.
    func testSlackContextKeyIsConfirmable() throws {
        let db = try AppDatabase.inMemory()
        var s = Session(kind: "slack", startedAt: 100, endedAt: 200, durationSeconds: 100,
                        contextKey: "slack:C07ABCDEF", createdAt: 0)
        s.clientId = "c1"
        let id = try db.insertSession(s)
        let ref = try XCTUnwrap(RecapWindow.signalToConfirm(
            db: db,
            suggestion: Suggestion(day: "d", kind: "session", clientId: "c1", minutes: 15,
                                   rawSeconds: 900, confidence: 0.8, producedByRung: 2,
                                   sourceRefsJson: "{\"sessions\":[\(id)]}", createdAt: 0, updatedAt: 0)))
        XCTAssertEqual(ref.type, "slack_channel")
        XCTAssertEqual(ref.value, "C07ABCDEF")
    }

    /// An `app:` key names a TOOL. Confirming it would attribute every future use of Slack.app or
    /// Xcode to whichever client happened to be on screen first.
    func testAppContextKeysAreNotConfirmed() throws {
        let db = try AppDatabase.inMemory()
        var s = Session(kind: "screen", startedAt: 100, endedAt: 200, durationSeconds: 100,
                        contextKey: "app:com.apple.mail", createdAt: 0)
        s.clientId = "c1"
        let id = try db.insertSession(s)
        XCTAssertNil(RecapWindow.signalToConfirm(
            db: db,
            suggestion: Suggestion(day: "d", kind: "session", clientId: "c1", minutes: 15,
                                   rawSeconds: 900, confidence: 0.8, producedByRung: 2,
                                   sourceRefsJson: "{\"sessions\":[\(id)]}", createdAt: 0, updatedAt: 0)))
    }

    func testPoolSuggestionsHaveNothingToConfirm() throws {
        let db = try AppDatabase.inMemory()
        XCTAssertNil(RecapWindow.signalToConfirm(
            db: db,
            suggestion: Suggestion(day: "d", kind: "pool", clientId: "c1", minutes: 15,
                                   rawSeconds: 900, confidence: 0.5, producedByRung: 2,
                                   sourceRefsJson: "{\"pool_id\":7}", createdAt: 0, updatedAt: 0)))
    }

    // MARK: The recap scheduler

    /// `recap.time` was decoded, displayed in Settings, dumped into diagnostics — and read by
    /// nothing that could act on it. There was no wall-clock timer in the tree at all.
    func testNextRecapIsTodayWhenTheTimeIsStillAhead() throws {
        let tz = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 8, day: 28, hour: 9)))
        let due = try XCTUnwrap(AppEnvironment.nextRecap(after: now, time: "17:00", timeZone: tz))
        XCTAssertEqual(cal.component(.hour, from: due), 17)
        XCTAssertEqual(cal.component(.day, from: due), 28)
    }

    /// Past the hour, it must arm for tomorrow rather than firing immediately in a loop.
    func testNextRecapRollsToTomorrowOnceThePointHasPassed() throws {
        let tz = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 8, day: 28, hour: 18)))
        let due = try XCTUnwrap(AppEnvironment.nextRecap(after: now, time: "17:00", timeZone: tz))
        XCTAssertEqual(cal.component(.day, from: due), 29)
        XCTAssertGreaterThan(due, now)
    }

    /// A typo in config must not crash the app or schedule something surprising.
    func testMalformedRecapTimeYieldsNil() {
        let tz = TimeZone(identifier: "UTC")!
        for bad in ["", "17", "5pm", "25:00", "17:99", "abc:def", "17:00:00"] {
            XCTAssertNil(AppEnvironment.nextRecap(after: Date(), time: bad, timeZone: tz), bad)
        }
    }

    func testRecapHonoursTheConfiguredTimezone() throws {
        let ny = TimeZone(identifier: "America/New_York")!
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        let a = try XCTUnwrap(AppEnvironment.nextRecap(after: now, time: "17:00", timeZone: ny))
        let b = try XCTUnwrap(AppEnvironment.nextRecap(after: now, time: "17:00", timeZone: la))
        XCTAssertNotEqual(a, b, "5pm is a different instant in each zone")
    }

    // MARK: Ask-once questions

    /// The recap's Questions section was permanently empty — the generator had no caller, so the
    /// manual repair channel was closed alongside the automatic one.
    func testRecurringUnresolvedHostBecomesOneQuestion() throws {
        let db = try AppDatabase.inMemory()
        for i in 0..<3 {
            try db.insertSession(Session(kind: "screen", startedAt: 100 + Int64(i) * 10,
                                         endedAt: 105 + Int64(i) * 10, durationSeconds: 5,
                                         contextKey: "web:mystery.example", createdAt: 0))
        }
        let created = try ResolutionQuestionGenerator().generate(db, from: 0, to: 10_000, now: 1)
        XCTAssertEqual(created, 1, "one question per host, not one per session")
        let q = try XCTUnwrap(try db.openQuestions().first)
        XCTAssertTrue(q.question.contains("mystery.example"))

        // Re-running must not pile up duplicates — it runs every pipeline pass.
        try ResolutionQuestionGenerator().generate(db, from: 0, to: 10_000, now: 2)
        XCTAssertEqual(try db.openQuestions().count, 1)
    }

    func testASingleVisitDoesNotEarnAQuestion() throws {
        let db = try AppDatabase.inMemory()
        try db.insertSession(Session(kind: "screen", startedAt: 100, endedAt: 105, durationSeconds: 5,
                                     contextKey: "web:once.example", createdAt: 0))
        XCTAssertEqual(try ResolutionQuestionGenerator().generate(db, from: 0, to: 10_000, now: 1), 0,
                       "do not pester about a one-off")
    }
}

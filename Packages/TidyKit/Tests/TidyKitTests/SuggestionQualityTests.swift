import XCTest
import Foundation
import TidyCore
import TidyStore
import TidySuggest
import TidyUnderstand

/// Two numbers on every card are the user's only triage tools: **minutes**, which they will bill,
/// and **confidence**, which tells them which card to check. Live, both were lying.
///
/// Ten pools holding 80 real minutes suggested 150, because inflation scales with the *number* of
/// pools and three of them held under four minutes. And 9 of 14 cards read exactly 0.82, so the
/// confidence column ordered nothing and meant nothing.
final class SuggestionQualityTests: XCTestCase {
    private let day = "2026-08-28"
    private let from: Int64 = 1_000
    private let to: Int64 = 900_000

    private func seed(_ db: AppDatabase, clients: Int) throws {
        for i in 1...clients {
            try db.upsertCompanies([PDCompany(id: "c\(i)", name: "Client \(i)", syncedAt: 0)])
            try db.upsertProjects([PDProject(id: "p\(i)", companyId: "c\(i)", name: "Proj \(i)", syncedAt: 0)])
        }
    }

    @discardableResult
    private func session(_ db: AppDatabase, client: String, project: String?, seconds: Int,
                         confidence: Double = 0.8, rung: Int = 2, at: Int64 = 2_000) throws -> Int64 {
        var s = Session(kind: "screen", startedAt: at, endedAt: at + Int64(seconds),
                        durationSeconds: seconds, title: "work", createdAt: 0)
        s.clientId = client; s.projectId = project
        s.confidence = confidence; s.producedByRung = rung
        return try db.insertSession(s)
    }

    // MARK: Pool inflation

    /// The live shape, reproduced: three pools under four minutes each buying a full 15-minute card.
    func testPoolsTooSmallToBillAreNotSuggested() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, clients: 3)
        try session(db, client: "c1", project: "p1", seconds: 72,  at: 2_000)   // 1.2 min
        try session(db, client: "c2", project: "p2", seconds: 150, at: 20_000)  // 2.5 min
        try session(db, client: "c3", project: "p3", seconds: 600, at: 40_000)  // 10 min

        let summary = try SuggestionEngine(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)))
            .generate(day: day, from: from, to: to)

        XCTAssertEqual(summary.pools, 1, "only the 10-minute pool is worth a billing increment")
        XCTAssertEqual(summary.droppedBelowPoolThreshold, 2)
        XCTAssertEqual(summary.droppedPoolSeconds, 222, "and it says so — dropping time silently is worse")
        XCTAssertEqual(try db.suggestions(day: day).map(\.minutes), [15])
    }

    /// Total inflation is what the user actually bills. Before this, the same input produced 45.
    func testTheDayDoesNotInflateThreefold() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, clients: 3)
        try session(db, client: "c1", project: "p1", seconds: 72,  at: 2_000)
        try session(db, client: "c2", project: "p2", seconds: 150, at: 20_000)
        try session(db, client: "c3", project: "p3", seconds: 600, at: 40_000)
        try SuggestionEngine(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)))
            .generate(day: day, from: from, to: to)

        let s = try db.suggestions(day: day)
        let suggested = s.reduce(0) { $0 + $1.minutes }
        let raw = Double(s.reduce(0) { $0 + $1.rawSeconds }) / 60.0
        XCTAssertLessThan(Double(suggested) / raw, 1.6, "\(suggested)m suggested for \(raw)m observed")
    }

    /// The floor must be configurable, and the production path must actually pass it — the
    /// "configured but not enforced" defect this repo keeps hitting.
    func testPoolThresholdIsConfigurable() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, clients: 1)
        try session(db, client: "c1", project: "p1", seconds: 600)   // 10 min

        XCTAssertEqual(try SuggestionEngine(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)),
                                            poolThresholdMinutes: 12)
                        .generate(day: day, from: from, to: to).pools, 0)
        XCTAssertEqual(try SuggestionEngine(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)),
                                            poolThresholdMinutes: 5)
                        .generate(day: day, from: from, to: to).pools, 1)
    }

    func testConfigCarriesThePoolThreshold() throws {
        XCTAssertEqual(Config().suggestions.poolThresholdMinutes, 5)
        let json = #"{"suggestions":{"pool_threshold_minutes":9}}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(c.suggestions.poolThresholdMinutes, 9)
        XCTAssertEqual(c.suggestions.incrementMinutes, 15, "other fields keep their defaults")
    }

    // MARK: Confidence has to discriminate

    /// `max` let one exact-URL session speak for a group that is mostly guesswork.
    func testGroupConfidenceIsDurationWeightedNotTheBestSession() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, clients: 1)
        try db.upsertTasks([PDTask(id: "t1", projectId: "p1", title: "T", syncedAt: 0)])
        // 5 minutes of certainty, 55 minutes of guessing, same task.
        for (seconds, conf, rung, at) in [(300, 0.97, 1, Int64(2_000)), (3_300, 0.50, 2, Int64(20_000))] {
            var s = Session(kind: "screen", startedAt: at, endedAt: at + Int64(seconds),
                            durationSeconds: seconds, title: "work", createdAt: 0)
            s.clientId = "c1"; s.projectId = "p1"; s.taskId = "t1"
            s.confidence = conf; s.producedByRung = rung
            try db.insertSession(s)
        }
        try SuggestionEngine(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)))
            .generate(day: day, from: from, to: to)

        let c = try XCTUnwrap(try db.suggestions(day: day).first?.confidence)
        XCTAssertLessThan(c, 0.65, "a card that is 92% guesswork by time must not read 0.97")
        XCTAssertGreaterThan(c, 0.50, "nor ignore the certain part entirely")
    }

    /// Confidence must order cards. A constant is not a measurement.
    func testKeywordConfidenceRisesWithCorroboration() throws {
        func classify(signals: [(String, String)], title: String) -> Double? {
            let rows = signals.map {
                EntitySignal(signalType: "keyword", signalValue: $0.0, clientId: $0.1,
                             provenance: "bootstrapped", weight: 1.0, createdAt: 0, updatedAt: 0)
            }
            var s = Session(kind: "screen", startedAt: 100, endedAt: 200, durationSeconds: 100,
                            title: title, createdAt: 0)
            s.id = 1
            return Classifier(companies: [PDCompany(id: "c1", name: "Acme", syncedAt: 0)],
                              projects: [], tasks: [], signals: rows).classify(s)?.confidence
        }

        let one = try XCTUnwrap(classify(signals: [("acme", "c1")], title: "acme notes"))
        let three = try XCTUnwrap(classify(signals: [("acme", "c1"), ("donation", "c1"), ("selector", "c1")],
                                           title: "acme donation selector"))
        XCTAssertGreaterThan(three, one, "three independent tokens naming one client beats one token")
        XCTAssertLessThan(three, 0.85, "still below an exact hostname match — words are never unambiguous")
        XCTAssertGreaterThan(one, 0.70)
    }
}

import XCTest
import Foundation
import TidyCore
import TidyStore
import TidyUnderstand

final class TokenizerTests: XCTestCase {
    func testFiltersShortAndStopwords() {
        XCTAssertEqual(Set(Tokenizer.tokens("The Acme Website re go")), ["acme", "website"])
        XCTAssertTrue(Tokenizer.tokens(nil).isEmpty)
    }
}

final class EntityBootstrapTests: XCTestCase {
    func testCreatesDomainSignals() throws {
        let db = try AppDatabase.inMemory()
        try db.upsertCompanies([PDCompany(id: "c1", name: "Acme", domain: "Acme.org", syncedAt: 1)])
        try EntityBootstrap().run(db, now: 100)
        let sig = try db.signals(values: ["acme.org"])
        XCTAssertEqual(Set(sig.map(\.signalType)), ["url_host", "email_domain"])
        XCTAssertEqual(sig.first?.clientId, "c1")
        // The bootstrap also mints a `keyword` signal from the company NAME now — on a real
        // workspace 0 of 687 companies carry a domain, so name tokens are what actually build the
        // vocabulary. Asserting an exact total here would just pin today's source count.
        XCTAssertEqual(try db.signals(values: ["acme"]).first?.clientId, "c1")
    }
}

final class ClassifierTests: XCTestCase {
    private func seed(_ db: AppDatabase) throws {
        try db.upsertCompanies([
            PDCompany(id: "acme", name: "Acme Nonprofit", domain: "acme.org", syncedAt: 1),
            PDCompany(id: "beta", name: "Beta Foundation", syncedAt: 1),
        ])
        try db.upsertProjects([
            PDProject(id: "p1", companyId: "acme", name: "Donation Page", projectTypeId: 2, syncedAt: 1),
        ])
        try db.upsertTasks([PDTask(id: "t1", projectId: "p1", title: "Build donation form", syncedAt: 1)])
        try EntityBootstrap().run(db, now: 1)  // acme.org signal
    }

    func testRung1MatchesDomainSignal() throws {
        let db = try AppDatabase.inMemory(); try seed(db)
        let c = try Classifier.load(db)
        let session = Session(kind: "screen", startedAt: 0, endedAt: 100, durationSeconds: 100,
                              contextKey: "web:acme.org", createdAt: 0)
        let result = c.classify(session)
        XCTAssertEqual(result?.clientId, "acme")
        XCTAssertEqual(result?.rung, 1)
    }

    /// Beta has no *domain* signal, so this used to fall through to rung-2 lexical scoring. It now
    /// resolves at **rung 1** on the `keyword` signals the bootstrap mints from company names —
    /// same answer, reached by a direct rule instead of scoring. Asserting rung 2 here would be
    /// pinning the weaker path.
    func testNameTokensResolveAtRungOne() throws {
        let db = try AppDatabase.inMemory(); try seed(db)
        let c = try Classifier.load(db)
        let session = Session(kind: "screen", startedAt: 0, endedAt: 100, durationSeconds: 100,
                              title: "Beta Foundation planning", contextKey: "app:com.apple.mail", createdAt: 0)
        let result = c.classify(session)
        XCTAssertEqual(result?.clientId, "beta")
        XCTAssertEqual(result?.rung, 1)
        XCTAssertEqual(result?.matchedSignalType, "keyword", "so the right rule gets strengthened")
    }

    /// Rung 2 is still reachable: a task title is not bootstrapped vocabulary, so a session that
    /// only matches task words has no keyword signal to hit and falls through to lexical scoring.
    func testRung2StillReachableViaTaskTitles() throws {
        let db = try AppDatabase.inMemory(); try seed(db)
        let c = try Classifier.load(db)
        let session = Session(kind: "screen", startedAt: 0, endedAt: 100, durationSeconds: 100,
                              title: "build the form", contextKey: "app:com.apple.mail", createdAt: 0)
        let result = c.classify(session)
        XCTAssertEqual(result?.clientId, "acme", "matched the task 'Build donation form'")
        XCTAssertEqual(result?.rung, 2)
    }

    func testAmbiguousLexicalReturnsNil() throws {
        let db = try AppDatabase.inMemory()
        try db.upsertCompanies([
            PDCompany(id: "a", name: "Shared Word", syncedAt: 1),
            PDCompany(id: "b", name: "Shared Thing", syncedAt: 1),
        ])
        let c = try Classifier.load(db)
        // "shared" matches both companies equally → ambiguous → nil.
        let session = Session(kind: "screen", startedAt: 0, endedAt: 100, durationSeconds: 100,
                              title: "shared", createdAt: 0)
        XCTAssertNil(c.classify(session))
    }

    func testMeetingClassifiesByInviteeDomain() throws {
        let db = try AppDatabase.inMemory(); try seed(db)
        let c = try Classifier.load(db)
        let session = Session(kind: "meeting", startedAt: 0, endedAt: 100, durationSeconds: 100,
                              title: "Weekly sync", sourceRef: "m1", createdAt: 0)
        let invitees = [MeetingInvitee(meetingId: "m1", email: "ceo@acme.org", emailDomain: "acme.org", isExternal: true)]
        let result = c.classify(session, invitees: invitees)
        XCTAssertEqual(result?.clientId, "acme")
        XCTAssertEqual(result?.rung, 1)
    }
}

final class DayClassifierTests: XCTestCase {
    func testClassifiesSessionsInDB() throws {
        let db = try AppDatabase.inMemory()
        try db.upsertCompanies([PDCompany(id: "acme", name: "Acme", domain: "acme.org", syncedAt: 1)])
        try EntityBootstrap().run(db, now: 1)
        try db.insertSession(Session(kind: "screen", startedAt: 1000, endedAt: 2000, durationSeconds: 1000,
                                     contextKey: "web:acme.org", createdAt: 0))
        try db.insertSession(Session(kind: "screen", startedAt: 3000, endedAt: 3100, durationSeconds: 100,
                                     contextKey: "web:unknown.example", createdAt: 0))
        let result = try DayClassifier().run(db, from: 0, to: 100_000, now: 500)
        XCTAssertEqual(result.classified, 1)
        XCTAssertEqual(result.unresolved, 1)
        let classified = try db.sessions(from: 0, to: 100_000).first { $0.clientId == "acme" }
        XCTAssertNotNil(classified)
        XCTAssertEqual(classified?.producedByRung, 1)
    }
}

final class DecisionRecorderTests: XCTestCase {
    func testReassignCreatesUserConfirmedSignal() throws {
        let db = try AppDatabase.inMemory()
        let sid = try db.insertSuggestion(Suggestion(day: "2026-07-22", kind: "session", minutes: 15,
                                                     rawSeconds: 900, confidence: 0.5, producedByRung: 2,
                                                     createdAt: 0, updatedAt: 0))
        let recorder = DecisionRecorder(db: db, clock: FixedClock(Date(timeIntervalSince1970: 999)))
        _ = try recorder.record(suggestionId: sid, action: "reassign", clientId: "acme",
                                confirmSignal: .init(type: "url_host", value: "staging.acme.org"))
        // decision recorded, suggestion status updated, and a user-confirmed rule now exists
        XCTAssertEqual(try db.decisions().count, 1)
        XCTAssertEqual(try db.suggestions(day: "2026-07-22").first?.status, "reassigned")
        let sig = try db.signals(values: ["staging.acme.org"]).first
        XCTAssertEqual(sig?.provenance, "user_confirmed")
        XCTAssertEqual(sig?.clientId, "acme")
    }
}

final class ResolutionQuestionTests: XCTestCase {
    func testGeneratesForRecurringUnresolvedHost() throws {
        let db = try AppDatabase.inMemory()
        for start in [1000, 2000, 3000] {
            try db.insertSession(Session(kind: "screen", startedAt: Int64(start), endedAt: Int64(start + 100),
                                         durationSeconds: 100, contextKey: "web:staging.example.org", createdAt: 0))
        }
        let created = try ResolutionQuestionGenerator(minOccurrences: 2).generate(db, from: 0, to: 100_000, now: 5)
        XCTAssertEqual(created, 1)
        XCTAssertEqual(try db.openQuestions().first?.signalValue, "staging.example.org")
    }
}

final class SensitivityGateTests: XCTestCase {
    func testDetectsConfiguredTerms() {
        let gate = SensitivityGate(terms: ["salary", "PIP", "Nancy"])
        XCTAssertTrue(gate.isSensitive("discussed the PIP for the new hire"))
        XCTAssertTrue(gate.isSensitive("Nancy's compensation review"))  // case-insensitive
        XCTAssertFalse(gate.isSensitive("reviewed the donation page"))
        XCTAssertNil(gate.gated("salary discussion"))
        XCTAssertEqual(gate.gated("donation page work"), "donation page work")
    }
    func testFromConfig() {
        var cfg = Config()
        cfg.sensitivity = .init(keywords: ["severance"], flaggedPeople: ["Bob"], flaggedTerms: [])
        let gate = SensitivityGate(config: cfg)
        XCTAssertTrue(gate.isSensitive("Bob severance package"))
    }
}

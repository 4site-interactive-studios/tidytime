import XCTest
import Foundation
import TidyCore
import TidyStore
import TidyUnderstand

/// `EntityBootstrap` only ever emitted `url_host`/`email_domain` from `pd_companies.domain`. On the
/// workspace this was built against, **0 of 687 companies carry a domain** — so wiring it would have
/// inserted zero signals and rung 1 would have stayed dead. Name tokens are what actually build the
/// vocabulary.
///
/// The precision rule under test: a token becomes a signal only when every name containing it maps
/// to the **same** client. A confident wrong attribution is worse than none — the user has to notice
/// it and undo it.
final class EntityBootstrapTokenTests: XCTestCase {
    private func seed(_ db: AppDatabase,
                      companies: [(String, String, String?)],
                      projects: [(String, String, String)] = []) throws {
        try db.upsertCompanies(companies.map {
            PDCompany(id: $0.0, name: $0.1, domain: $0.2, archived: false, syncedAt: 0)
        })
        try db.upsertProjects(projects.map {
            PDProject(id: $0.0, companyId: $0.1, name: $0.2, archived: false, syncedAt: 0)
        })
    }

    private func signals(_ db: AppDatabase) throws -> [String: EntitySignal] {
        Dictionary(uniqueKeysWithValues: try db.allSignals().map { ($0.signalValue, $0) })
    }

    // MARK: The ambiguity guard — the whole point

    /// "video" appears under two different clients, so it identifies neither and must not be minted.
    /// "engrid" belongs to one, so it is a real signal. No stop-list could know this.
    func testAmbiguousTokensAreNotMinted() throws {
        let db = try AppDatabase.inMemory()
        try seed(db,
                 companies: [("c1", "Acme Foundation", nil), ("c2", "Beta Trust", nil)],
                 projects: [("p1", "c1", "Acme ENgrid Migration"),
                            ("p2", "c1", "Acme Video Series"),
                            ("p3", "c2", "Beta Video Series")])

        let created = try EntityBootstrap().run(db, now: 100)
        let byValue = try signals(db)

        XCTAssertNil(byValue["video"], "a token under two clients identifies neither")
        XCTAssertNil(byValue["series"], "same")
        XCTAssertEqual(byValue["engrid"]?.clientId, "c1", "unique to one client — mint it")
        XCTAssertEqual(byValue["acme"]?.clientId, "c1")
        XCTAssertEqual(byValue["beta"]?.clientId, "c2")
        XCTAssertGreaterThan(created, 0)
    }

    /// The cross-source case: a token in company A's NAME and in a project belonging to company B.
    /// `clientsByToken` must union both sources, or a token would look unique per-source and get
    /// minted against whichever the loop saw.
    func testTokenSharedBetweenACompanyNameAndAnotherClientsProjectIsRejected() throws {
        let db = try AppDatabase.inMemory()
        try seed(db,
                 companies: [("c1", "Horizon Foundation", nil), ("c2", "Beta Trust", nil)],
                 projects: [("p1", "c2", "Beta Horizon Rebuild")])
        try EntityBootstrap().run(db, now: 100)
        XCTAssertNil(try signals(db)["horizon"],
                     "shared across a company name and another client's project — identifies neither")
        XCTAssertEqual(try signals(db)["beta"]?.clientId, "c2", "unshared tokens still mint")
    }

    /// A token unique to one client AND one project carries the project too; unique to the client
    /// but spread across projects still resolves the client, which is the more valuable half.
    func testProjectIsAttachedOnlyWhenUnambiguous() throws {
        let db = try AppDatabase.inMemory()
        try seed(db,
                 companies: [("c1", "Acme Foundation", nil)],
                 projects: [("p1", "c1", "Acme ENgrid Migration"),
                            ("p2", "c1", "Acme Donation Pages")])
        try EntityBootstrap().run(db, now: 100)
        let byValue = try signals(db)

        XCTAssertEqual(byValue["engrid"]?.projectId, "p1", "unique to one project")
        XCTAssertEqual(byValue["acme"]?.clientId, "c1")
        XCTAssertNil(byValue["acme"]?.projectId, "spans two projects — client only")
    }

    /// A project with no company is unattributable. Before `include=` was sent, EVERY project was in
    /// this state — minting from it would have attached tokens to an empty client id.
    func testProjectsWithNoCompanyAreSkipped() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, companies: [], projects: [("p1", "", "Orphan ENgrid Work")])
        try EntityBootstrap().run(db, now: 100)
        XCTAssertTrue(try db.allSignals().isEmpty, "no signal may carry an empty client id")
    }

    /// Our own tooling and calendar vocabulary would otherwise pass the ambiguity test whenever one
    /// client happens to own the only project mentioning it.
    func testHouseTokensAreExcluded() throws {
        let db = try AppDatabase.inMemory()
        try seed(db,
                 companies: [("c1", "4Site Interactive Studios", nil)],
                 projects: [("p1", "c1", "4Site Internal Operations Retainer")])
        try EntityBootstrap().run(db, now: 100)
        let byValue = try signals(db)
        for token in ["4site", "internal", "operations", "retainer"] {
            XCTAssertNil(byValue[token], "\(token) names our own work, not a client")
        }
    }

    // MARK: Domains still work where they exist

    func testDomainsStillProduceHostAndEmailSignals() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, companies: [("c1", "Acme Foundation", "acme.org")])
        try EntityBootstrap().run(db, now: 100)
        let types = Set(try db.allSignals().filter { $0.signalValue == "acme.org" }.map(\.signalType))
        XCTAssertEqual(types, ["url_host", "email_domain"])
    }

    // MARK: Safe to re-run

    /// The bootstrap runs on every pipeline pass. It must never duplicate, and — critically — never
    /// overwrite a `user_confirmed` signal, which outranks bootstrapped forever.
    func testRerunIsIdempotentAndPreservesUserConfirmed() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, companies: [("c1", "Acme Foundation", "acme.org")])
        try EntityBootstrap().run(db, now: 100)
        let first = try db.allSignals().count

        // The user corrects one of them.
        try db.strengthenSignal(type: "keyword", value: "acme", clientId: "c99", projectId: nil,
                                provenance: "user_confirmed", now: 200)

        try EntityBootstrap().run(db, now: 300)
        XCTAssertEqual(try db.allSignals().count, first, "re-running must not duplicate")

        let acme = try XCTUnwrap(try db.allSignals().first { $0.signalValue == "acme" })
        XCTAssertEqual(acme.provenance, "user_confirmed", "the user's correction must survive")
        XCTAssertEqual(acme.clientId, "c99")
    }

    // MARK: Cost — this runs on the pipeline cadence

    /// Measured on the real workspace: 687 companies + 965 projects yield ~1,186 unambiguous
    /// tokens. One write transaction each, every 300s, forever, to re-insert rows that already
    /// exist. The vocabulary changes on the order of days, so the second pass must be a no-op.
    func testSecondRunIsThrottledToANoOp() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, companies: [("c1", "Acme Foundation", "acme.org")])

        XCTAssertGreaterThan(try EntityBootstrap().run(db, now: 100), 0)
        XCTAssertEqual(try EntityBootstrap().run(db, now: 200), 0,
                       "nothing changed and no time passed — must not re-derive")
        XCTAssertEqual(try EntityBootstrap().run(db, now: 100 + 86_399), 0,
                       "still inside the interval with an identical cache")

        // After the interval it DOES re-derive, deliberately. The fingerprint is only
        // "companies:projects" counts, so a RENAMED project changes nothing it can see — without a
        // periodic re-derive the vocabulary would go stale forever. One batched transaction a day
        // is the price of catching that.
        XCTAssertGreaterThan(try EntityBootstrap().run(db, now: 100 + 86_400), 0,
                             "a daily re-derive catches renames the count fingerprint cannot see")
    }

    /// A fresh Productive sync must re-derive immediately rather than waiting out the interval —
    /// otherwise new clients stay invisible for a day.
    func testCacheChangeReDerivesImmediately() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, companies: [("c1", "Acme Foundation", nil)])
        XCTAssertGreaterThan(try EntityBootstrap().run(db, now: 100), 0)
        XCTAssertEqual(try EntityBootstrap().run(db, now: 110), 0)

        try seed(db, companies: [("c1", "Acme Foundation", nil), ("c2", "Beta Trust", nil)])
        XCTAssertGreaterThan(try EntityBootstrap().run(db, now: 120), 0,
                             "the mirror grew — re-derive now, not tomorrow")
        XCTAssertEqual(try db.signals(values: ["beta"]).first?.clientId, "c2")
    }

    func testForceBypassesTheThrottle() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, companies: [("c1", "Acme Foundation", nil)])
        try EntityBootstrap().run(db, now: 100)
        XCTAssertGreaterThan(try EntityBootstrap().run(db, now: 110, force: true), 0)
    }

    func testEmptyCacheProducesNothingAndDoesNotThrow() throws {
        let db = try AppDatabase.inMemory()
        XCTAssertEqual(try EntityBootstrap().run(db, now: 100), 0)
    }
}

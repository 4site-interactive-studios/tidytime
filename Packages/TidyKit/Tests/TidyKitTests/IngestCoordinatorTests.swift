import XCTest
import Foundation
import TidyCore
import TidyStore
import TidySurface

/// The readiness logic is what turns "this table is mysteriously zero" into a stated reason.
/// It's pure (no network), so it's fully testable.
final class IngestReadinessTests: XCTestCase {
    private func coordinator(config: Config, secrets: [String: String]) throws -> IngestCoordinator {
        IngestCoordinator(db: try AppDatabase.inMemory(), config: config,
                          secrets: InMemorySecretStore(secrets),
                          clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_000)))
    }

    private var configuredOrg: Config {
        var c = Config()
        c.organization.productiveOrganizationId = "42"
        return c
    }

    func testNoCredentialIsReportedNotSilentlyIdle() throws {
        let c = try coordinator(config: configuredOrg, secrets: [:])
        XCTAssertEqual(c.readiness(.slack), .missingCredential(SecretKey.slackUserToken))
        XCTAssertEqual(c.readiness(.fathom), .missingCredential(SecretKey.fathomKey))
        XCTAssertFalse(c.readiness(.slack).canRun)
        XCTAssertTrue(c.readiness(.slack).explanation.contains("slack.user_token"))
    }

    func testTokenPresentMakesSourceReady() throws {
        let c = try coordinator(config: configuredOrg, secrets: [SecretKey.slackUserToken: "xoxp-x"])
        XCTAssertEqual(c.readiness(.slack), .ready)
    }

    /// The exact situation in the first real run: a token exists but org id was never set.
    func testProductiveNeedsOrgIdEvenWithAToken() throws {
        let c = try coordinator(config: Config(), secrets: [SecretKey.productiveToken: "tok"])
        XCTAssertEqual(c.readiness(.productive), .missingConfig("organization.productive_organization_id"))
        // The placeholder from config.example.json must not count as configured either.
        var placeholder = Config()
        placeholder.organization.productiveOrganizationId = "REPLACE_WITH_ORG_ID"
        let c2 = try coordinator(config: placeholder, secrets: [SecretKey.productiveToken: "tok"])
        XCTAssertEqual(c2.readiness(.productive), .missingConfig("organization.productive_organization_id"))
    }

    func testEmptyStringTokenDoesNotCountAsPresent() throws {
        let c = try coordinator(config: configuredOrg, secrets: [SecretKey.fathomKey: ""])
        XCTAssertEqual(c.readiness(.fathom), .missingCredential(SecretKey.fathomKey))
    }

    func testKillSwitchIsReported() throws {
        var cfg = configuredOrg
        cfg.capture.killSwitches.slack = false
        cfg.capture.killSwitches.fathom = false
        let c = try coordinator(config: cfg, secrets: [SecretKey.slackUserToken: "x", SecretKey.fathomKey: "y"])
        XCTAssertEqual(c.readiness(.slack), .disabledByKillSwitch)
        XCTAssertEqual(c.readiness(.fathom), .disabledByKillSwitch)
    }

    /// Google must say WHY it can't run — it has no OAuth flow, which is not the user's fault.
    func testGoogleReportsNotImplementedRatherThanMissingCredential() throws {
        let c = try coordinator(config: configuredOrg, secrets: [SecretKey.googleRefreshToken: "tok"])
        guard case .notImplemented(let why) = c.readiness(.googleCalendar) else {
            return XCTFail("expected notImplemented, got \(c.readiness(.googleCalendar))")
        }
        XCTAssertTrue(why.lowercased().contains("oauth"))
    }

    func testReadinessReportCoversEverySource() throws {
        let c = try coordinator(config: configuredOrg, secrets: [:])
        XCTAssertEqual(c.readinessReport().count, IngestCoordinator.Source.allCases.count)
    }

    func testDateWindowIsInclusiveYMD() {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let (after, before) = IngestCoordinator.dateWindow(days: 30, clock: clock, tz: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(after.count, 10)   // YYYY-MM-DD
        XCTAssertEqual(before.count, 10)
        XCTAssertLessThan(after, before)
    }
}

/// The diagnostic bundle must describe the cadences the app actually uses.
final class DiagnosticsFreshnessTests: XCTestCase {
    func testSummaryReportsRealCadencesNotLegacyHeartbeat() {
        let summary = DiagnosticsAssembler.summarize(Config())
        XCTAssertNotNil(summary["detection_interval_s"])
        XCTAssertNotNil(summary["content_interval_s"])
        XCTAssertNotNil(summary["separate_chats_by_path"])
        XCTAssertNil(summary["heartbeat_s"], "legacy heartbeat is superseded and would mislead a debugger")
    }
}

/// The read-only DB path the `tidytime-doctor` CLI uses must never mutate a database the app has open.
final class ReadOnlyDatabaseTests: XCTestCase {
    func testOpenReadOnlyReadsButCannotWrite() throws {
        let dir = try TestSupport.makeTempDir(); defer { TestSupport.cleanup(dir) }
        let url = dir.appendingPathComponent("t.sqlite")
        // Create + populate with a normal (migrating) open.
        do {
            let db = try AppDatabase.open(at: url)
            try db.setMetadata("greeting", "hello", clock: FixedClock(Date(timeIntervalSince1970: 1)))
        }
        let ro = try AppDatabase.openReadOnly(at: url)
        XCTAssertEqual(try ro.metadata("greeting"), "hello", "read-only open must still read")
        XCTAssertFalse(try ro.tableRowCounts().isEmpty)
        XCTAssertThrowsError(try ro.setMetadata("greeting", "nope"),
                             "a read-only handle must refuse writes")
    }
}

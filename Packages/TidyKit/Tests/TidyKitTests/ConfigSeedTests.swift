import XCTest
import Foundation
import TidyCore

/// First-launch `config.json` seeding. The behaviour that matters most here is the negative one:
/// an existing file is never touched.
final class ConfigSeedTests: XCTestCase {
    private var dir: URL!
    private var paths: AppPaths!

    override func setUpWithError() throws {
        dir = try TestSupport.makeTempDir()
        paths = try AppPaths(supportDirectory: dir).ensureDirectories()
    }

    override func tearDown() { TestSupport.cleanup(dir) }

    func testSeedsWhenAbsent() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configURL.path))
        XCTAssertEqual(ConfigSeeder().seedIfMissing(at: paths.configURL), .wrote)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.configURL.path))
    }

    /// The seeded file must be loadable by the very loader the app uses — a starter file that
    /// throws on parse would be worse than no file at all.
    func testSeededFileParsesAndKeepsCompiledDefaults() throws {
        ConfigSeeder().seedIfMissing(at: paths.configURL)
        let loaded = try ConfigLoader().load(from: paths.configURL)
        let defaults = Config()

        // Blocks the seed omits entirely must still come back as their compiled defaults.
        XCTAssertEqual(loaded.capture.contentIntervalSeconds, defaults.capture.contentIntervalSeconds)
        XCTAssertEqual(loaded.capture.idleThresholdSeconds, defaults.capture.idleThresholdSeconds)
        XCTAssertEqual(loaded.sessionization.detourToleranceSeconds, defaults.sessionization.detourToleranceSeconds)
        XCTAssertEqual(loaded.suggestions.incrementMinutes, defaults.suggestions.incrementMinutes)
        XCTAssertEqual(loaded.recap.time, defaults.recap.time)
        XCTAssertEqual(loaded.retentionDays, defaults.retentionDays)
        XCTAssertEqual(loaded.productive.baseUrl, defaults.productive.baseUrl)
        XCTAssertEqual(loaded.productive.taskDeepLinkPattern, defaults.productive.taskDeepLinkPattern)
    }

    /// Guards the whole point of the seed policy: no placeholder may override a working default.
    /// The `ai` block is the sharp edge — unverified model slugs plus a null-priced entry that the
    /// ledger would silently value at $0, disabling that model's G5 daily cap.
    func testSeedCarriesNoPlaceholdersOrAIBlock() throws {
        ConfigSeeder().seedIfMissing(at: paths.configURL)
        let raw = try String(contentsOf: paths.configURL, encoding: .utf8)

        XCTAssertFalse(raw.contains("REPLACE_WITH"), "a placeholder would defeat the isEmpty guards")
        XCTAssertFalse(raw.contains("resolved_at_setup"))
        XCTAssertFalse(raw.contains("\"ai\""), "seeding the ai block would override working defaults")
        XCTAssertFalse(raw.contains("prices_usd_per_mtok"))
        XCTAssertFalse(raw.contains("kimi"), "model slugs are unverified and churn — never seed them")
        XCTAssertFalse(raw.contains("null"), "a null price silently costs $0 and disables the cap")

        // And the loaded result must be the clean unconfigured state, not a half-configured one.
        let loaded = try ConfigLoader().load(from: paths.configURL)
        XCTAssertTrue(loaded.organization.productiveOrganizationId.isEmpty,
                      "an empty org id keeps Doctor's 'paste your org id' tip firing")
        XCTAssertTrue(loaded.google.clientId.isEmpty,
                      "a placeholder client_id defeats the isEmpty check and yields an opaque OAuth error")
        XCTAssertTrue(loaded.ai.models.isEmpty)
        XCTAssertTrue(loaded.ai.routing.isEmpty)
    }

    /// The non-negotiable one. The machine this came from had a hand-written config.json with a
    /// real org id; overwriting or merging would have destroyed it.
    func testNeverOverwritesAnExistingFile() throws {
        let handWritten = #"{"organization":{"productive_organization_id":"2650"}}"#
        try handWritten.write(to: paths.configURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(ConfigSeeder().seedIfMissing(at: paths.configURL), .alreadyExists)
        XCTAssertEqual(try String(contentsOf: paths.configURL, encoding: .utf8), handWritten)

        // Repeated launches keep leaving it alone.
        for _ in 0..<3 { ConfigSeeder().seedIfMissing(at: paths.configURL) }
        XCTAssertEqual(try String(contentsOf: paths.configURL, encoding: .utf8), handWritten)
        XCTAssertEqual(try ConfigLoader().load(from: paths.configURL).organization.productiveOrganizationId, "2650")
    }

    /// Even an empty or corrupt file is a file. Seeding over it would destroy evidence of the very
    /// parse error the user is trying to fix.
    func testDoesNotReplaceAnEmptyOrCorruptFile() throws {
        for existing in ["", "{ this is not json"] {
            try existing.write(to: paths.configURL, atomically: true, encoding: .utf8)
            XCTAssertEqual(ConfigSeeder().seedIfMissing(at: paths.configURL), .alreadyExists)
            XCTAssertEqual(try String(contentsOf: paths.configURL, encoding: .utf8), existing)
        }
    }

    func testFailureIsReportedNotThrown() {
        // A path inside a file (not a directory) cannot be written — the app must survive it.
        let impossible = paths.configURL.appendingPathComponent("nested/config.json")
        try? Data("x".utf8).write(to: paths.configURL)
        guard case .failed = ConfigSeeder().seedIfMissing(at: impossible) else {
            return XCTFail("expected a reported failure, not a crash or a silent success")
        }
    }
}

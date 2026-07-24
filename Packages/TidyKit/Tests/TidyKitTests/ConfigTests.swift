import XCTest
import Foundation
import TidyCore

final class ConfigTests: XCTestCase {
    func testEmptyJSONLoadsDefaults() throws {
        let dir = try TestSupport.makeTempDir(); defer { TestSupport.cleanup(dir) }
        let url = dir.appendingPathComponent("config.json")
        try "{}".data(using: .utf8)!.write(to: url)
        let cfg = try ConfigLoader().load(from: url)
        XCTAssertEqual(cfg.suggestions.incrementMinutes, 15)
        XCTAssertEqual(cfg.capture.idleThresholdSeconds, 600)
        XCTAssertEqual(cfg.sessionization.detourToleranceSeconds, 120)
        XCTAssertEqual(cfg.retentionDays["activity_samples"], 90)
        XCTAssertEqual(cfg.recap.time, "17:00")
    }

    func testMissingFileReturnsDefaults() throws {
        let url = URL(fileURLWithPath: "/nonexistent/tidytime/config.json")
        let cfg = try ConfigLoader().load(from: url)
        XCTAssertEqual(cfg, Config())
    }

    func testMalformedJSONThrows() throws {
        let dir = try TestSupport.makeTempDir(); defer { TestSupport.cleanup(dir) }
        let url = dir.appendingPathComponent("config.json")
        try "{ not json".data(using: .utf8)!.write(to: url)
        XCTAssertThrowsError(try ConfigLoader().load(from: url))
    }

    func testPartialOverrideKeepsOtherDefaults() throws {
        let dir = try TestSupport.makeTempDir(); defer { TestSupport.cleanup(dir) }
        let url = dir.appendingPathComponent("config.json")
        try #"{ "suggestions": { "round_up_bias": 0.6 } }"#.data(using: .utf8)!.write(to: url)
        let cfg = try ConfigLoader().load(from: url)
        XCTAssertEqual(cfg.suggestions.roundUpBias, 0.6)
        XCTAssertEqual(cfg.suggestions.incrementMinutes, 15) // untouched default
    }

    /// The committed config.example.json must round-trip through the model (schema stays in sync).
    func testCommittedExampleConfigLoads() throws {
        let url = TestSupport.repoRoot().appendingPathComponent("config.example.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "config.example.json not found at \(url.path)")
        let cfg = try ConfigLoader().load(from: url)
        XCTAssertEqual(cfg.organization.timezone, "America/New_York")
        XCTAssertEqual(cfg.suggestions.incrementMinutes, 15)
        XCTAssertEqual(cfg.capture.killSwitches.slack, true)
        XCTAssertEqual(cfg.retentionDays["page_snapshots"], 90)
        XCTAssertEqual(cfg.ingest.googleCalendar.pollIntervalSeconds, 300)
        XCTAssertNotNil(cfg.ai.models["fireworks-economy"])
        // Claude prices are intentionally null in the example (build-time check).
        XCTAssertNil(cfg.ai.pricesUsdPerMtok["claude-opus-4-8"]?.input ?? nil)
    }
}

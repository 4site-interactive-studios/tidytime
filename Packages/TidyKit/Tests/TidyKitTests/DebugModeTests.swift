import XCTest
import Foundation
import TidyCore
import TidyStore

/// End-to-end test of the manual debug mode: assemble a diagnostic bundle from live-ish sources
/// (in-memory DB, in-memory secrets holding a real token value, a temp log file) and "copy" it to a
/// fake clipboard. Asserts the bundle is useful AND never leaks a secret value (guardrail G6).
final class DebugModeTests: XCTestCase {
    func testCopyDiagnosticsProducesRedactedUsefulBundle() throws {
        let dir = try TestSupport.makeTempDir(); defer { TestSupport.cleanup(dir) }
        let db = try AppDatabase.inMemory()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        try db.setMetadata("greeting", "hi", clock: clock)

        // A secret VALUE is present in the store — its name may appear, its value must not.
        let tokenValue = "xoxp-REAL-secret-value-1234"
        let secrets = InMemorySecretStore([SecretKey.slackUserToken: tokenValue])

        // A log file that (badly) contains the token — the bundle must scrub it.
        let logURL = dir.appendingPathComponent("logs/tidytime.jsonl")
        let sink = try FileLogSink(url: logURL)
        TidyLogger(category: "test", sink: sink).info("startup ok")
        // simulate a stray secret in an older log line
        try "raw line with token=\(tokenValue)\n".data(using: .utf8)!
            .write(to: logURL.appendingPathExtension("bak"))

        let assembler = DiagnosticsAssembler(
            db: db, config: Config(), secrets: secrets, logURL: logURL,
            permissions: StaticPermissionProvider(["Accessibility": "granted"]), clock: clock
        )
        let clip = FakeClipboard()
        assembler.copyDiagnostics(using: clip, knownSecretValues: [tokenValue])

        let bundle = try XCTUnwrap(clip.last)
        // Useful:
        XCTAssertTrue(bundle.contains("## Database"))
        XCTAssertTrue(bundle.contains("app_metadata: 1"))
        XCTAssertTrue(bundle.contains("Accessibility: granted"))
        XCTAssertTrue(bundle.contains(SecretKey.slackUserToken)) // the NAME is fine
        // Safe:
        XCTAssertFalse(bundle.contains(tokenValue), "secret VALUE leaked into the diagnostic bundle")
    }

    func testConfigSummaryHasNoSecrets() {
        let summary = DiagnosticsAssembler.summarize(Config())
        XCTAssertEqual(summary["timezone"], "America/New_York")
        // No key in the summary should carry a token/secret.
        for (_, v) in summary { XCTAssertFalse(v.lowercased().contains("token")) }
    }
}

import XCTest
import Foundation
import TidyCore

final class DiagnosticsTests: XCTestCase {
    private func sampleInput() -> DiagnosticsInput {
        DiagnosticsInput(
            appVersion: "0.1.0",
            osVersion: "macOS 26.5",
            deviceModel: "Mac15,3",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            configSummary: ["org_id": "42", "timezone": "America/New_York"],
            presentSecretKeys: [SecretKey.productiveToken, SecretKey.fathomKey],
            permissions: ["Accessibility": "granted", "Automation(Chrome)": "not-determined"],
            databaseSummary: ["app_metadata": 2, "sessions": 0],
            recentLogLines: [#"{"level":"info","message":"synced"}"#],
            extras: ["build": "debug"]
        )
    }

    func testRenderIncludesAllSections() {
        let out = DiagnosticsBundle.render(sampleInput())
        for header in ["# TidyTime diagnostic bundle", "## Environment", "## Permissions",
                       "## Config (non-secret)", "## Credentials present", "## Database",
                       "## Recent logs"] {
            XCTAssertTrue(out.contains(header), "missing section: \(header)")
        }
        XCTAssertTrue(out.contains("app_metadata: 2"))
        XCTAssertTrue(out.contains(SecretKey.productiveToken))
    }

    /// Guardrail G6: a secret value seeded anywhere in the inputs must NOT survive rendering.
    func testGuardrailNoSecretLeaksIntoBundle() {
        var input = sampleInput()
        let secret = "xoxp-99-should-never-appear"
        input.recentLogLines.append("accidentally logged token=\(secret)")
        input.extras["oops"] = secret
        let out = DiagnosticsBundle.render(input, secrets: [secret])
        XCTAssertFalse(out.contains(secret), "secret leaked into diagnostic bundle")
        XCTAssertTrue(out.contains(Redactor.mask))
    }

    func testFakeClipboardCapturesCopy() {
        let clip = FakeClipboard()
        let text = DiagnosticsBundle.render(sampleInput())
        clip.copy(text)
        XCTAssertEqual(clip.last, text)
    }
}

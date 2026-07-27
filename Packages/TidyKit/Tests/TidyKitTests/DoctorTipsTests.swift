import XCTest
import Foundation
import TidyCore
import TidySurface

/// The Doctor troubleshooting layer is pure — these tests pin the severity table, guarantee every
/// non-healthy status has a plain-language tip, and check the tips encode the failure modes that
/// cost real support round-trips this session.
final class StatusSeverityTests: XCTestCase {
    /// The regression that motivated this type: a healthy stable signature rendered orange.
    func testStableSignatureClassifiesHealthy() {
        XCTAssertEqual(StatusSeverity.classify("stable (team QCUYJGV4J5, id: com.4site.TidyTime)"), .healthy)
    }

    func testSeverityMatrix() {
        let cases: [(String, StatusSeverity)] = [
            ("granted", .healthy),
            ("denied", .broken),
            ("not granted", .attention),
            ("not determined", .attention),
            ("not requested (by design — G3)", .neutral),
            ("app not running", .neutral),          // probe can't run until the target app is open
            ("provisional", .neutral),
            ("ephemeral", .attention),
            ("unknown", .attention),
            ("unknown (-1743)", .attention),
            ("⚠️ AD-HOC (id: TidyTime) — TCC grants will NOT persist; set DEVELOPMENT_TEAM", .attention),
        ]
        for (status, expected) in cases {
            XCTAssertEqual(StatusSeverity.classify(status), expected, "for status: \(status)")
        }
    }
}

final class DoctorPermissionTipsTests: XCTestCase {
    func testHealthyStatusesHaveNoTip() {
        XCTAssertNil(DoctorTips.tip(forPermission: "Accessibility", status: "granted"))
        XCTAssertNil(DoctorTips.tip(forPermission: "Code signature",
                                    status: "stable (team X, id: com.4site.TidyTime)"))
        XCTAssertNil(DoctorTips.tip(forPermission: "Screen Recording",
                                    status: "not requested (by design — G3)"))
    }

    func testEveryNonHealthyPermissionStatusHasATip() {
        let rows: [(String, [String])] = [
            ("Accessibility", ["not granted"]),
            ("Automation (Chrome)", ["denied", "not determined", "app not running", "unknown (-1)"]),
            ("Automation (System Events)", ["denied", "not determined", "app not running"]),
            ("Notifications", ["denied", "not determined", "ephemeral"]),
            ("Code signature", ["⚠️ AD-HOC (id: x) — TCC grants will NOT persist; set DEVELOPMENT_TEAM", "unknown"]),
        ]
        for (row, statuses) in rows {
            for status in statuses {
                let tip = DoctorTips.tip(forPermission: row, status: status)
                XCTAssertNotNil(tip, "\(row) / \(status) has no tip")
                XCTAssertFalse(tip?.steps.isEmpty ?? true, "\(row) / \(status) tip has no steps")
            }
        }
    }

    /// The two failure modes that actually bit during first-run support.
    func testAccessibilityTipCoversRelaunchAndStaleRow() {
        let joined = DoctorTips.tip(forPermission: "Accessibility", status: "not granted")!
            .steps.joined(separator: " ").lowercased()
        XCTAssertTrue(joined.contains("relaunch"), "must tell the user a relaunch may be needed")
        XCTAssertTrue(joined.contains("minus"), "must explain removing the stale row with −, not toggling")
        XCTAssertEqual(DoctorTips.tip(forPermission: "Accessibility", status: "not granted")?.settingsPane,
                       "Privacy_Accessibility")
    }

    func testAdhocTipNamesTheActualFix() {
        let joined = DoctorTips.tip(forPermission: "Code signature",
                                    status: "⚠️ AD-HOC (id: x) — TCC grants will NOT persist; set DEVELOPMENT_TEAM")!
            .steps.joined(separator: " ")
        XCTAssertTrue(joined.contains("DEVELOPMENT_TEAM"))
        XCTAssertTrue(joined.contains("find-team-id"))
    }

    func testSystemEventsNotRunningTipSaysItIsNormal() {
        let joined = DoctorTips.tip(forPermission: "Automation (System Events)", status: "app not running")!
            .steps.joined(separator: " ").lowercased()
        XCTAssertTrue(joined.contains("normal"))
    }
}

final class DoctorIngestTipsTests: XCTestCase {
    private let path = "/Users/x/Library/Application Support/TidyTime/config.json"

    func testReadyWithNoErrorHasNoTip() {
        XCTAssertNil(DoctorTips.tip(for: .slack, readiness: .ready, lastError: nil, configPath: path))
    }

    func testReadyWithErrorShowsErrorAndHint() {
        let tip = DoctorTips.tip(for: .slack, readiness: .ready,
                                 lastError: #"http 429: {"ok":false,"error":"ratelimited"}"#,
                                 configPath: path)!
        let joined = tip.steps.joined(separator: " ")
        XCTAssertTrue(joined.contains("429"), "raw error must be visible")
        XCTAssertTrue(joined.lowercased().contains("slow down"), "429 hint must de-dramatize")
    }

    func testProductiveOrgIdTipShowsConfigPathAndURLTrick() {
        let tip = DoctorTips.tip(for: .productive,
                                 readiness: .missingConfig("organization.productive_organization_id"),
                                 lastError: nil, configPath: path)!
        let joined = tip.steps.joined(separator: " ")
        XCTAssertTrue(joined.contains(path), "must name the exact file on this machine")
        XCTAssertTrue(joined.contains("app.productive.io"), "must teach the address-bar trick")
    }

    func testMissingCredentialPointsAtSettingsWithHumanName() {
        let tip = DoctorTips.tip(for: .fathom,
                                 readiness: .missingCredential(SecretKey.fathomKey),
                                 lastError: nil, configPath: path)!
        let joined = tip.steps.joined(separator: " ")
        XCTAssertTrue(joined.contains("Fathom API key"), "human name, not the dotted key")
        XCTAssertTrue(joined.contains("Credentials"))
    }

    func testNeedsSignInOffersTheButton() {
        let tip = DoctorTips.tip(for: .googleCalendar,
                                 readiness: .needsSignIn("click Sign in with Google in Settings → Credentials"),
                                 lastError: nil, configPath: path)!
        XCTAssertTrue(tip.offersGoogleSignIn)
    }

    func testKillSwitchTipNamesConfig() {
        let tip = DoctorTips.tip(for: .fathom, readiness: .disabledByKillSwitch,
                                 lastError: nil, configPath: path)!
        XCTAssertTrue(tip.steps.joined(separator: " ").contains("kill_switches"))
    }

    func testLastErrorHints() {
        XCTAssertTrue(DoctorTips.hint(forLastError: "http 429: ratelimited")!.contains("retries"))
        XCTAssertTrue(DoctorTips.hint(forLastError: "slack error: invalid_auth")!.contains("Credentials"))
        XCTAssertTrue(DoctorTips.hint(forLastError: "refresh token rejected (sign in again): expired")!
            .contains("Sign in"))
        XCTAssertTrue(DoctorTips.hint(forLastError: "transport error: request timed out")!.lowercased()
            .contains("network"))
        XCTAssertNil(DoctorTips.hint(forLastError: "something completely novel"))
    }

    /// The naming shim must cover every known key (superseded by CredentialCatalog in commit 3).
    func testDisplayNamesCoverAllSecretKeys() {
        for key in SecretKey.all {
            XCTAssertNotEqual(CredentialCatalogNaming.displayName(for: key), key,
                              "no human name for \(key)")
        }
    }
}

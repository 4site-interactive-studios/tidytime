import XCTest
import Foundation
import TidyCore
import TidyStore
import TidyCapture
import TidySurface

/// `page_snapshots` was 0 for the entire life of the database while 34,586 Chrome URLs were
/// captured. The cause was environmental — Chrome's "Allow JavaScript from Apple Events" toggle
/// was off — but the *defect* was that nothing anywhere said so.
final class ChromeJavaScriptStatusTests: XCTestCase {

    // MARK: The degrade itself

    private func makeChromeCoordinator(jsEnabled: Bool)
        throws -> (AppDatabase, FakeBrowserAdapter, CaptureCoordinator) {
        let db = try AppDatabase.inMemory()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let reader = MutableFrontmostReader(FrontmostContext(
            appBundleId: "com.google.Chrome", appName: "Chrome", isBrowser: true))
        let browser = FakeBrowserAdapter(
            tab: BrowserTab(url: "https://example.com/a", title: "A"),
            pageText: "some visible text",
            jsEnabled: jsEnabled)
        return (db, browser, CaptureCoordinator(reader: reader, browser: browser,
                                                recorder: SampleRecorder(db: db, clock: clock)))
    }

    /// With the toggle off, URL/title capture keeps working and page text does not. That asymmetry
    /// — 34,586 samples with URLs, 0 snapshots — is the whole diagnostic signature, and no test
    /// covered it before: `grep jsEnabled Tests/` matched nothing.
    func testTogglingOffStopsSnapshotsButNotSamples() throws {
        let (db, _, coordinator) = try makeChromeCoordinator(jsEnabled: false)

        XCTAssertTrue(try coordinator.poll())
        try coordinator.captureContent()

        let counts = try db.tableRowCounts()
        XCTAssertGreaterThan(counts["activity_samples"] ?? 0, 0,
                             "URL/title capture needs only Automation and must keep working")
        XCTAssertEqual(counts["page_snapshots"], 0,
                       "page text needs the Chrome JS toggle; without it there is nothing to store")
        XCTAssertEqual(try db.samples(from: 0, to: 2_000_000_000).first?.url, "https://example.com/a",
                       "the URL is still captured — that is what made the failure look healthy")
    }

    func testSnapshotsAppearOnceTheToggleIsOn() throws {
        let (db, _, coordinator) = try makeChromeCoordinator(jsEnabled: true)
        XCTAssertTrue(try coordinator.poll())
        try coordinator.captureContent()
        XCTAssertGreaterThan(try db.tableRowCounts()["page_snapshots"] ?? 0, 0)
    }

    // MARK: Probe classification — saying WHICH failure it is

    func testProbeDistinguishesTheFailureModes() {
        XCTAssertEqual(
            ChromeJavaScriptProbe.classify(result: "1", errorNumber: nil, errorMessage: nil),
            ChromeJavaScriptProbe.ok)

        // Chrome's refusal is plain language, not a distinct error number.
        XCTAssertEqual(
            ChromeJavaScriptProbe.classify(
                result: nil, errorNumber: -2700,
                errorMessage: "Executing JavaScript through AppleScript is turned off."),
            ChromeJavaScriptProbe.toggleOff)

        XCTAssertEqual(
            ChromeJavaScriptProbe.classify(result: nil, errorNumber: -1743, errorMessage: "not authorized"),
            ChromeJavaScriptProbe.automationDenied)
        XCTAssertEqual(
            ChromeJavaScriptProbe.classify(result: nil, errorNumber: -1744, errorMessage: "consent required"),
            ChromeJavaScriptProbe.notDetermined)
        XCTAssertEqual(
            ChromeJavaScriptProbe.classify(result: nil, errorNumber: -600, errorMessage: "not running"),
            ChromeJavaScriptProbe.notRunning)
    }

    /// Only `ok` permits capture — an unknown outcome must not be optimistically treated as fine.
    func testOnlyOkCountsAsEnabled() {
        XCTAssertTrue(ChromeJavaScriptProbe.isEnabled(ChromeJavaScriptProbe.ok))
        for status in [ChromeJavaScriptProbe.toggleOff, ChromeJavaScriptProbe.automationDenied,
                       ChromeJavaScriptProbe.notDetermined, ChromeJavaScriptProbe.notRunning,
                       ChromeJavaScriptProbe.unknown] {
            XCTAssertFalse(ChromeJavaScriptProbe.isEnabled(status), status)
        }
    }

    // MARK: The row has to reach the places that claim to show it

    /// `permissions-setup.md` tells the user to verify with `make doctor` → Chrome JS = `ok`.
    /// That row must actually survive the render → parse round-trip the CLI performs.
    func testTheRowSurvivesTheDiagnosticsRoundTrip() {
        let input = DiagnosticsInput(
            appVersion: "0.1.0", osVersion: "macOS 26.5", deviceModel: "Mac15,3",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            permissions: [
                "Accessibility": "granted",
                ChromeJavaScriptProbe.statusKey: ChromeJavaScriptProbe.toggleOff,
            ])
        let rendered = DiagnosticsBundle.render(input)
        XCTAssertTrue(rendered.contains(ChromeJavaScriptProbe.statusKey))

        let parsed = DiagnosticsAssembler.permissions(fromSnapshot: rendered)
        XCTAssertEqual(parsed[ChromeJavaScriptProbe.statusKey], ChromeJavaScriptProbe.toggleOff,
                       "the doctor CLI drops any key missing from its allow-list")
    }

    /// A degraded row must carry an actionable tip — a status with no remedy is the silent failure
    /// in a different costume.
    func testToggleOffOffersTheExactClickPath() throws {
        let tip = try XCTUnwrap(DoctorTips.tip(forPermission: ChromeJavaScriptProbe.statusKey,
                                               status: ChromeJavaScriptProbe.toggleOff))
        let text = tip.steps.joined(separator: " ")
        XCTAssertTrue(text.contains("View"))
        XCTAssertTrue(text.contains("Developer"))
        XCTAssertTrue(text.contains("Allow JavaScript from Apple Events"))
        XCTAssertTrue(text.contains("not a macOS permission") || text.contains("not appear in System Settings"),
                      "the user must be told not to hunt for this in System Settings")
    }

    func testHealthyRowNeedsNoTip() {
        XCTAssertNil(DoctorTips.tip(forPermission: ChromeJavaScriptProbe.statusKey, status: ChromeJavaScriptProbe.ok))
    }

    func testAutomationDeniedPointsAtTheUpstreamRowInstead() throws {
        let tip = try XCTUnwrap(DoctorTips.tip(forPermission: ChromeJavaScriptProbe.statusKey,
                                               status: ChromeJavaScriptProbe.automationDenied))
        XCTAssertTrue(tip.steps.joined(separator: " ").contains("Automation (Chrome)"),
                      "fixing this row first is pointless if Apple Events can't reach Chrome at all")
    }
}

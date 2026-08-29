import XCTest
import Foundation
import TidyCore
import TidyStore
import TidyCapture

/// The app had **no exclusion mechanism of any kind**. Private browsing, a banking tab, a personal
/// messages client — everything the Accessibility API and the browser adapter could see was written
/// to `activity_samples`, and the only remedy on offer was the global kill switch, which is an off
/// button rather than a control.
///
/// Every assertion here is about a row NOT existing. Retention deleting it later, or the recap
/// hiding it, would both be too late: the raw title would already be on disk.
final class CaptureExclusionTests: XCTestCase {
    private func make(_ reader: MutableFrontmostReader, browser: BrowserAdapter? = nil,
                      exclusions: CaptureExclusions = CaptureExclusions())
        throws -> (AppDatabase, FixedClock, CaptureCoordinator) {
        let db = try AppDatabase.inMemory()
        let clock = FixedClock(Date(timeIntervalSince1970: 1000))
        return (db, clock, CaptureCoordinator(
            reader: reader, browser: browser, recorder: SampleRecorder(db: db, clock: clock),
            exclusions: exclusions))
    }

    private func chrome() -> MutableFrontmostReader {
        MutableFrontmostReader(FrontmostContext(appBundleId: "com.google.Chrome", appName: "Chrome",
                                                isBrowser: true))
    }

    // MARK: Private browsing — never recorded, no configuration required

    /// Opening an incognito window is an unambiguous statement about being observed. Honouring it
    /// is not something the user should have to find a setting for.
    func testIncognitoIsNeverRecorded() throws {
        let reader = chrome()
        let adapter = FakeBrowserAdapter(tab: BrowserTab(url: "https://example.com/x", title: "X",
                                                         isPrivate: true))
        let (db, _, coord) = try make(reader, browser: adapter)
        XCTAssertFalse(try coord.poll())
        XCTAssertEqual(try db.tableRowCounts()["activity_samples"], 0)
    }

    /// Not even the URL or the title — the tab is dropped before either is copied onto the context.
    func testNothingAboutAPrivateTabSurvives() throws {
        let reader = chrome()
        let adapter = FakeBrowserAdapter(tab: BrowserTab(url: "https://clinic.example/portal",
                                                         title: "Appointment", isPrivate: true),
                                         pageText: "confidential body text")
        let (db, _, coord) = try make(reader, browser: adapter)
        _ = try coord.poll()
        try coord.captureContent()
        XCTAssertEqual(try db.tableRowCounts()["activity_samples"], 0)
        XCTAssertEqual(try db.tableRowCounts()["page_snapshots"], 0)
    }

    /// Stepping out of the private window must record normally again — an exclusion that poisons
    /// the session afterwards would look like the capture had broken.
    func testNormalBrowsingResumesAfterAPrivateWindow() throws {
        let reader = chrome()
        let adapter = FakeBrowserAdapter(tab: BrowserTab(url: "https://acme.org/a", title: "A"))
        let (db, clock, coord) = try make(reader, browser: adapter)
        XCTAssertTrue(try coord.poll())

        clock.advance(by: 1)
        adapter.tab = BrowserTab(url: "https://secret.example/x", title: "S", isPrivate: true)
        XCTAssertFalse(try coord.poll())

        clock.advance(by: 1)
        adapter.tab = BrowserTab(url: "https://acme.org/a", title: "A")
        XCTAssertTrue(try coord.poll(), "returning to the same page records a fresh sample")

        let samples = try db.samples(from: 0, to: 100_000)
        XCTAssertEqual(samples.count, 2)
        XCTAssertTrue(samples.allSatisfy { $0.url?.contains("acme.org") == true })
    }

    // MARK: Excluded hosts

    func testAnExcludedHostIsNotRecorded() throws {
        let reader = chrome()
        let adapter = FakeBrowserAdapter(tab: BrowserTab(url: "https://chase.com/accounts", title: "Bank"))
        let (db, _, coord) = try make(reader, browser: adapter,
                                      exclusions: CaptureExclusions(hosts: ["chase.com"]))
        XCTAssertFalse(try coord.poll())
        XCTAssertEqual(try db.tableRowCounts()["activity_samples"], 0)
    }

    /// Suffix matching, because `secure.chase.com` is the form the user is actually looking at.
    func testSubdomainsOfAnExcludedHostAreCovered() {
        let e = CaptureExclusions(hosts: ["chase.com"])
        XCTAssertTrue(e.excludes(url: "https://secure.chase.com/login"))
        XCTAssertTrue(e.excludes(url: "https://chase.com"))
        XCTAssertFalse(e.excludes(url: "https://notchase.completely.example/x"),
                       "a substring match here would silently over-exclude")
        XCTAssertFalse(e.excludes(url: "https://chase.com.evil.example/x"))
    }

    /// Hand-edited config carries bare hosts, not URLs. Rejecting those would be a trap.
    func testBareHostsParse() {
        XCTAssertEqual(CaptureExclusions.host(of: "chase.com"), "chase.com")
        XCTAssertEqual(CaptureExclusions.host(of: "https://a.b.com/x?y=1"), "a.b.com")
        XCTAssertNil(CaptureExclusions.host(of: "localhost"))
    }

    // MARK: Excluded apps

    func testAnExcludedAppIsNotRecorded() throws {
        let reader = MutableFrontmostReader(FrontmostContext(
            appBundleId: "com.agilebits.onepassword7", appName: "1Password", windowTitle: "Vault"))
        let (db, _, coord) = try make(reader, exclusions: CaptureExclusions(
            appBundleIds: ["com.agilebits.onepassword7"]))
        XCTAssertFalse(try coord.poll())
        XCTAssertEqual(try db.tableRowCounts()["activity_samples"], 0)
    }

    /// An excluded app's page text must not be filed under the last sample that WAS recorded.
    func testExcludedContextDoesNotInheritThePreviousSample() throws {
        let reader = chrome()
        let adapter = FakeBrowserAdapter(tab: BrowserTab(url: "https://acme.org/a", title: "A"),
                                         pageText: "ordinary work")
        let (db, clock, coord) = try make(reader, browser: adapter,
                                          exclusions: CaptureExclusions(hosts: ["chase.com"]))
        XCTAssertTrue(try coord.poll())
        try coord.captureContent()
        let before = try db.tableRowCounts()["page_snapshots"] ?? 0

        clock.advance(by: 1)
        adapter.tab = BrowserTab(url: "https://chase.com/accounts", title: "Bank")
        adapter.pageText = "balance $12,345"
        _ = try coord.poll()
        try coord.captureContent()

        XCTAssertEqual(try db.tableRowCounts()["page_snapshots"], before,
                       "the bank page's text must not be attached to the previous sample")
        XCTAssertFalse(try db.samples(from: 0, to: 100_000).contains { $0.url?.contains("chase") == true })
    }

    // MARK: Config and wiring

    func testConfigCarriesExclusions() throws {
        let json = #"{"capture":{"excluded_hosts":["chase.com"],"excluded_apps":["com.x.y"]}}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(c.capture.excludedHosts, ["chase.com"])
        XCTAssertEqual(CaptureExclusions(config: c).appBundleIds, ["com.x.y"])
        XCTAssertTrue(Config().capture.excludedHosts.isEmpty, "empty by default — no surprise gaps")
    }

    /// A correct component with no caller is this repo's signature defect; pin the call site.
    func testExclusionsAreWiredIntoLiveCapture() throws {
        let src = try String(
            contentsOf: TestSupport.repoRoot()
                .appendingPathComponent("Packages/TidyKit/Sources/TidyCapture/LiveCapture.swift"),
            encoding: .utf8)
        XCTAssertTrue(src.contains("CaptureExclusions(config: config)"))
        XCTAssertTrue(src.contains("mode of front window"),
                      "the Chrome adapter must actually ask whether the window is incognito")
    }
}

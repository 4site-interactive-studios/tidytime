import XCTest
import Foundation
import TidyCore
import TidyStore

/// Covers the build-provenance stamp added after the 2026-08-28 live debugging session, where a
/// stale build relaunching from the Trash was indistinguishable from the current install because
/// every diagnostic said only "0.1.0".
final class BuildProvenanceTests: XCTestCase {

    // MARK: BuildInfo

    func testUnknownWhenPlistKeysAreAbsent() {
        // `Bundle.main` under `swift test` is the test runner, which carries no TTGitSHA. The
        // point is that this reports "unknown" rather than inventing or crashing.
        let info = BuildInfo.current()
        XCTAssertEqual(info.gitSHA, BuildInfo.unknownValue)
        XCTAssertEqual(info.builtAt, BuildInfo.unknownValue)
        XCTAssertFalse(info.isProvenanceKnown)
        XCTAssertEqual(info.version, TidyTime.version)
    }

    func testSummaryNamesCommitAndBuildTime() {
        let info = BuildInfo(version: "0.1.0", gitSHA: "8dda588", builtAt: "2026-07-27T12:53:16Z",
                             bundlePath: "/Applications/TidyTime.app")
        XCTAssertEqual(info.summary, "0.1.0 (8dda588, built 2026-07-27T12:53:16Z)")
        XCTAssertTrue(info.isProvenanceKnown)
    }

    /// An Xcode build that never set TT_GIT_SHA leaves the literal `$(TT_GIT_SHA)` in the plist.
    /// Echoing that back as a commit would be worse than admitting ignorance.
    func testUnsubstitutedBuildSettingIsTreatedAsUnknown() {
        let values = [
            BuildInfo.PlistKey.gitSHA: "$(TT_GIT_SHA)",
            BuildInfo.PlistKey.builtAt: "   ",
        ]
        let info = BuildInfo.resolve(bundlePath: "/x") { values[$0] }
        XCTAssertEqual(info.gitSHA, BuildInfo.unknownValue)
        XCTAssertEqual(info.builtAt, BuildInfo.unknownValue)
    }

    func testReadsStampedValuesFromBundle() {
        let values = [
            BuildInfo.PlistKey.gitSHA: "8dda588",
            BuildInfo.PlistKey.builtAt: "2026-07-27T12:53:16Z",
        ]
        let info = BuildInfo.resolve(bundlePath: "/Applications/TidyTime.app") { values[$0] }
        XCTAssertEqual(info.gitSHA, "8dda588")
        XCTAssertEqual(info.builtAt, "2026-07-27T12:53:16Z")
        XCTAssertEqual(info.bundlePath, "/Applications/TidyTime.app")
        XCTAssertTrue(info.isProvenanceKnown)
    }

    // MARK: Rendering

    func testBundleRendersShaTimestampAndPath() {
        let input = DiagnosticsInput(
            appVersion: "0.1.0", osVersion: "macOS 26.5", deviceModel: "Mac15,3",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            build: BuildInfo(version: "0.1.0", gitSHA: "8dda588",
                             builtAt: "2026-07-27T12:53:16Z",
                             bundlePath: "/Applications/TidyTime.app"))
        let out = DiagnosticsBundle.render(input)
        XCTAssertTrue(out.contains("- Git SHA: 8dda588"))
        XCTAssertTrue(out.contains("- Built at: 2026-07-27T12:53:16Z"))
        XCTAssertTrue(out.contains("- Bundle path: /Applications/TidyTime.app"))
    }

    /// The distinguishing case from 2026-08-28: two bundles, same version string, different paths.
    /// The rendered bundle has to make them tell-apart-able at a glance.
    func testStaleCopyIsDistinguishableFromInstalledCopy() {
        func render(sha: String, path: String) -> String {
            DiagnosticsBundle.render(DiagnosticsInput(
                appVersion: "0.1.0", osVersion: "macOS 26.5", deviceModel: "Mac15,3",
                generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                build: BuildInfo(version: "0.1.0", gitSHA: sha, builtAt: "t", bundlePath: path)))
        }
        let stale = render(sha: "43ca776", path: "/Users/x/.Trash/TidyTime.app")
        let current = render(sha: "8dda588", path: "/Applications/TidyTime.app")
        XCTAssertNotEqual(stale, current)
        XCTAssertTrue(stale.contains(".Trash"))
        XCTAssertTrue(current.contains("/Applications/TidyTime.app"))
    }

    func testUnknownProvenanceIsCalledOutExplicitly() {
        let input = DiagnosticsInput(
            appVersion: "0.1.0", osVersion: "macOS 26.5", deviceModel: "Mac15,3",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            build: BuildInfo())
        let out = DiagnosticsBundle.render(input)
        XCTAssertTrue(out.contains("carries no git SHA"),
                      "a build with no provenance must say so, not stay silent")
    }

    // MARK: Persistence — the database remembers which build last opened it

    func testRecordedBuildSurvivesIntoExtras() throws {
        let db = try AppDatabase.inMemory()
        db.recordRunningBuild(BuildInfo(version: "0.1.0", gitSHA: "8dda588",
                                        builtAt: "2026-07-27T12:53:16Z",
                                        bundlePath: "/Applications/TidyTime.app"))

        XCTAssertEqual(try db.metadata(MetadataKey.lastRunBuild),
                       "0.1.0 (8dda588, built 2026-07-27T12:53:16Z)")
        XCTAssertEqual(try db.metadata(MetadataKey.lastRunBundlePath), "/Applications/TidyTime.app")

        // The CLI reads these back out of the DB — that is how `tidytime-doctor` reports the APP's
        // build while running as a different binary entirely.
        let extras = DiagnosticsAssembler.extras(
            db: db,
            build: BuildInfo(gitSHA: "irrelevant-cli-build"),
            logURL: URL(fileURLWithPath: "/tmp/x.jsonl"))
        XCTAssertEqual(extras["last_run_build"], "0.1.0 (8dda588, built 2026-07-27T12:53:16Z)")
        XCTAssertEqual(extras["last_run_bundle_path"], "/Applications/TidyTime.app")
    }

    /// A database written by a pre-provenance build must not claim a build it never recorded.
    func testDatabaseWithNoRecordedBuildSaysSo() throws {
        let db = try AppDatabase.inMemory()
        let extras = DiagnosticsAssembler.extras(
            db: db, build: BuildInfo(), logURL: URL(fileURLWithPath: "/tmp/x.jsonl"))
        XCTAssertTrue(extras["last_run_build"]?.contains("never recorded") == true)
    }

    func testLatestLaunchOverwritesThePrevious() throws {
        let db = try AppDatabase.inMemory()
        db.recordRunningBuild(BuildInfo(gitSHA: "43ca776", bundlePath: "/Users/x/.Trash/TidyTime.app"))
        db.recordRunningBuild(BuildInfo(gitSHA: "8dda588", bundlePath: "/Applications/TidyTime.app"))
        XCTAssertEqual(try db.metadata(MetadataKey.lastRunBundlePath), "/Applications/TidyTime.app")
        XCTAssertTrue(try db.metadata(MetadataKey.lastRunBuild)?.contains("8dda588") == true)
    }
}

import Foundation

/// Which build is actually running — the git commit, when it was built, and where the bundle lives.
///
/// Why this exists: on 2026-08-28 a live debugging session burned hours on symptoms that were
/// already fixed in `main`, because nothing anywhere said which commit the running process came
/// from. The installed `/Applications/TidyTime.app` was current; a **stale copy in the Trash** was
/// what actually launched (a leftover login-item registration still pointed at it). The version
/// string alone said `0.1.0` for both, so it could not distinguish them.
///
/// Three fields, each earning its place:
/// - ``gitSHA`` — the only thing that identifies the code. `0.1.0` is not a build.
/// - ``builtAt`` — separates two builds of the same commit (debug vs. the signed release).
/// - ``bundlePath`` — separates two *copies* of the same build. This is the field that would
///   have ended the confusion in one glance.
///
/// Stamped into the app's `Info.plist` at build time (`TTGitSHA` / `TTBuildTimestamp`, fed by the
/// `TT_GIT_SHA` / `TT_BUILD_TIMESTAMP` build settings the `Makefile` and `scripts/make-dmg.sh`
/// pass to `xcodebuild`). In any context without those keys — plain `swift test`, `swift run`, a
/// bare Xcode build — the fields read ``unknownValue`` rather than lying. A build that cannot
/// prove its provenance says so.
public struct BuildInfo: Sendable, Equatable {
    /// The placeholder used wherever provenance genuinely is not knowable.
    public static let unknownValue = "unknown"

    /// Marketing version, e.g. `0.1.0`.
    public var version: String
    /// Short git SHA the binary was built from, or ``unknownValue``.
    public var gitSHA: String
    /// ISO-8601 UTC build timestamp, or ``unknownValue``.
    public var builtAt: String
    /// Filesystem path of the running bundle/executable, or ``unknownValue``.
    public var bundlePath: String

    public init(version: String = TidyTime.version,
                gitSHA: String = BuildInfo.unknownValue,
                builtAt: String = BuildInfo.unknownValue,
                bundlePath: String = BuildInfo.unknownValue) {
        self.version = version
        self.gitSHA = gitSHA
        self.builtAt = builtAt
        self.bundlePath = bundlePath
    }

    /// Info.plist keys the build stamps. Kept here so `App/Info.plist` and the reader can't drift.
    public enum PlistKey {
        public static let gitSHA = "TTGitSHA"
        public static let builtAt = "TTBuildTimestamp"
    }

    /// True when the build could not identify its own commit — surfaced so a reader knows the
    /// difference between "built from abc1234" and "we have no idea what this is".
    ///
    /// Matches on the **prefix**, not equality, so a build script that decorates the fallback
    /// (`unknown-dirty` was a real bug here) still reads as unknown. Fail closed: a build wrongly
    /// claiming to know its commit is the exact failure this whole feature exists to prevent.
    public var isProvenanceKnown: Bool { !gitSHA.hasPrefix(Self.unknownValue) }

    /// One line for logs and the diagnostic bundle: `0.1.0 (8dda588, built 2026-07-27T12:53:16Z)`.
    public var summary: String {
        "\(version) (\(gitSHA), built \(builtAt))"
    }

    /// Read from a bundle's Info.plist. Defaults to the main bundle, which is the app when the app
    /// is running and the test runner under `swift test` — where the keys are absent and every
    /// field correctly reports `unknown`.
    public static func current(bundle: Bundle = .main) -> BuildInfo {
        resolve(bundlePath: bundle.bundleURL.path) { bundle.object(forInfoDictionaryKey: $0) as? String }
    }

    /// The testable seam. Takes the Info.plist lookup as a closure rather than a `Bundle` so tests
    /// can exercise stamped, missing, and unsubstituted values without subclassing `Bundle`
    /// (whose designated initializers can't be meaningfully overridden).
    public static func resolve(bundlePath: String, lookup: (String) -> String?) -> BuildInfo {
        BuildInfo(
            version: TidyTime.version,
            gitSHA: normalize(lookup(PlistKey.gitSHA)),
            builtAt: normalize(lookup(PlistKey.builtAt)),
            bundlePath: bundlePath
        )
    }

    /// Treat missing/empty/unsubstituted entries as unknown. The unsubstituted case is real: an
    /// Xcode build that never set `TT_GIT_SHA` leaves the literal `$(TT_GIT_SHA)` behind, and
    /// echoing that back as if it were a commit would be worse than admitting ignorance.
    private static func normalize(_ raw: String?) -> String {
        guard let raw else { return unknownValue }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return unknownValue }
        return trimmed
    }
}

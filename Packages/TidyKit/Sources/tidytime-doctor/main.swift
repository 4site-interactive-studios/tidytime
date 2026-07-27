// tidytime-doctor — print the redacted diagnostic bundle to stdout, with no app and no clicking.
//
// Why this exists: troubleshooting previously required a human to open the app, press "Copy
// diagnostics", and paste. This makes the same information readable by tooling (including an AI
// assistant) on demand:  swift run tidytime-doctor   /   make diagnose
//
// Two sources, because they know different things:
//  - **Live read** of the database, config, and logs — works whether or not the app is running, and
//    is always current. Opened READ-ONLY so it can never mutate a DB the app has open.
//  - **The app's own snapshot** (`diagnostics.md`), which is the only way to see the APP PROCESS's
//    TCC/permission status. macOS grants permissions per-binary, so this CLI asking about
//    Accessibility would report the CLI's answer, not TidyTime.app's — a genuinely misleading result.
//
// Redaction is unchanged: credentials appear by name only and the whole bundle is scrubbed.
import Foundation
import TidyCore
import TidyStore

let args = CommandLine.arguments
let wantsSnapshotOnly = args.contains("--snapshot")
let logLines = args.firstIndex(of: "--log-lines").flatMap { i -> Int? in
    i + 1 < args.count ? Int(args[i + 1]) : nil
} ?? 120

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard let paths = try? AppPaths.standard() else { fail("could not resolve ~/Library/Application Support/TidyTime") }

// The app's snapshot: the only source for this-app permission status.
let snapshot = try? String(contentsOf: paths.diagnosticsURL, encoding: .utf8)

if wantsSnapshotOnly {
    guard let snapshot else {
        fail("""
            No snapshot at \(paths.diagnosticsURL.path).
            The app writes one on each pipeline pass — launch TidyTime, or drop --snapshot to read
            the database directly.
            """)
    }
    print(snapshot)
    exit(0)
}

guard FileManager.default.fileExists(atPath: paths.databaseURL.path) else {
    fail("No database at \(paths.databaseURL.path) — TidyTime has not run yet.")
}

let db: AppDatabase
do { db = try AppDatabase.openReadOnly(at: paths.databaseURL) }
catch { fail("could not open the database read-only: \(error)") }

let config = ConfigLoader().loadOrDefault(from: paths.configURL)
let secrets = KeychainSecretStore()

// NOTE: permissions are deliberately NOT probed here — see the header. The app's snapshot carries
// the authoritative answer; we surface its freshness instead of a misleading local reading.
var permissions: [String: String] = [:]
if let snapshot {
    permissions = DiagnosticsAssembler.permissions(fromSnapshot: snapshot)
        .reduce(into: [:]) { $0[$1.key + " (from app snapshot)"] = $1.value }
}
if permissions.isEmpty {
    permissions["(app snapshot)"] = "none found — launch TidyTime to record its permission status"
}

let assembler = DiagnosticsAssembler(
    db: db, config: config, secrets: secrets, logURL: paths.currentLogURL,
    permissions: StaticPermissionProvider(permissions))

var input = assembler.assemble(logLines: logLines)
input.extras["read_by"] = "tidytime-doctor CLI (database opened read-only)"
if let attrs = try? FileManager.default.attributesOfItem(atPath: paths.diagnosticsURL.path),
   let modified = attrs[.modificationDate] as? Date {
    input.extras["app_snapshot_age"] = String(format: "%.0fs old", Date().timeIntervalSince(modified))
} else {
    input.extras["app_snapshot_age"] = "no snapshot (app not run since this feature landed)"
}

let known = SecretKey.all.compactMap { try? secrets.get($0) }.compactMap { $0 }
print(DiagnosticsBundle.render(input, secrets: known))

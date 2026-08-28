import Foundation
import TidyCore

/// Gathers a ``DiagnosticsInput`` from live sources (DB row counts, config summary, present secret
/// key NAMES, permission status, recent logs, environment) so the manual debug mode can render and
/// copy it. All assembly is testable; only the clipboard write and the real permission checks are
/// platform-bound.
public struct DiagnosticsAssembler: Sendable {
    private let db: AppDatabase
    private let config: Config
    private let secrets: SecretStore
    private let logURL: URL
    private let permissions: PermissionStatusProviding
    private let clock: TidyClock

    private let build: BuildInfo

    public init(
        db: AppDatabase, config: Config, secrets: SecretStore, logURL: URL,
        permissions: PermissionStatusProviding = StaticPermissionProvider(), clock: TidyClock = SystemClock(),
        build: BuildInfo = .current()
    ) {
        self.db = db; self.config = config; self.secrets = secrets; self.logURL = logURL
        self.permissions = permissions; self.clock = clock; self.build = build
    }

    public func assemble(logLines: Int = 200) -> DiagnosticsInput {
        DiagnosticsInput(
            appVersion: HostInfo.appVersion,
            osVersion: HostInfo.osVersion,
            deviceModel: HostInfo.deviceModel,
            generatedAt: clock.now,
            build: build,
            configSummary: Self.summarize(config),
            presentSecretKeys: (try? secrets.allKeys()) ?? [],
            permissions: permissions.statuses(),
            databaseSummary: (try? db.tableRowCounts()) ?? [:],
            recentLogLines: LogReader.tail(logURL, lines: logLines),
            extras: Self.extras(db: db, build: build, logURL: logURL)
        )
    }

    /// The `Extras` block. `last_run_*` are read back out of `app_metadata` rather than taken from
    /// this process, so the `tidytime-doctor` CLI — a different binary, with its own provenance —
    /// still reports which build last ran the **app**. Without that split the CLI would cheerfully
    /// describe itself and answer the wrong question.
    public static func extras(db: AppDatabase, build: BuildInfo, logURL: URL) -> [String: String] {
        var out: [String: String] = [
            "build": Self.buildConfiguration,
            "applied_migrations": (try? db.appliedMigrations().joined(separator: ",")) ?? "",
            "db_path": db.path ?? "in-memory",
            "log_path": logURL.path,
        ]
        let unknown = "(never recorded — no build since provenance landed has opened this database)"
        out["last_run_build"] = ((try? db.metadata(MetadataKey.lastRunBuild)) ?? nil) ?? unknown
        out["last_run_bundle_path"] = ((try? db.metadata(MetadataKey.lastRunBundlePath)) ?? nil) ?? unknown
        return out
    }

    /// Assemble → render → copy. `knownSecretValues` are extra values to scrub (belt-and-braces).
    public func copyDiagnostics(using clipboard: ClipboardWriter, knownSecretValues: [String] = []) {
        clipboard.copy(DiagnosticsBundle.render(assemble(), secrets: knownSecretValues))
    }

    static var buildConfiguration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    // MARK: Non-secret config summary

    /// Parse the permission lines back out of a rendered diagnostics snapshot. Used by the
    /// `tidytime-doctor` CLI, which cannot probe the APP's TCC status itself (per-binary) and so
    /// reports what the app recorded. Extracted here so the round-trip is testable against
    /// `DiagnosticsBundle.render` output (round-3 R2-6).
    public static func permissions(fromSnapshot snapshot: String) -> [String: String] {
        let known = ["Accessibility", "Automation (Chrome)", "Automation (System Events)",
                     "Code signature", "Notifications", "Screen Recording"]
        var out: [String: String] = [:]
        for line in snapshot.split(separator: "\n") where line.hasPrefix("- ") {
            let body = line.dropFirst(2)
            guard let colon = body.firstIndex(of: ":") else { continue }
            let key = String(body[..<colon])
            guard known.contains(key) else { continue }
            out[key] = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    public static func summarize(_ c: Config) -> [String: String] {
        [
            "org_id": c.organization.productiveOrganizationId.isEmpty ? "(unset)" : c.organization.productiveOrganizationId,
            "person_id": c.organization.productivePersonId.isEmpty ? "(unset)" : c.organization.productivePersonId,
            "timezone": c.organization.timezone,
            "browser": c.capture.browser,
            "idle_threshold_s": String(c.capture.idleThresholdSeconds),
            "detection_interval_s": String(c.capture.detectionIntervalSeconds),
            "content_interval_s": String(c.capture.contentIntervalSeconds),
            "separate_chats_by_path": String(c.capture.separateChatsByPath),
            "detour_tolerance_s": String(c.sessionization.detourToleranceSeconds),
            "increment_minutes": String(c.suggestions.incrementMinutes),
            "recap_time": c.recap.time,
            "nudges_enabled": String(c.nudges.enabled),
            "ai_enabled": String(c.ai.enabled),
            "kill_switches": "app=\(c.capture.killSwitches.appWatcher) chrome=\(c.capture.killSwitches.chrome) cal=\(c.capture.killSwitches.calendar) fathom=\(c.capture.killSwitches.fathom) slack=\(c.capture.killSwitches.slack)",
        ]
    }
}

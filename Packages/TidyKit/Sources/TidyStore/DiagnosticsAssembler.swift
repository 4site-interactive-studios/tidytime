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

    public init(
        db: AppDatabase, config: Config, secrets: SecretStore, logURL: URL,
        permissions: PermissionStatusProviding = StaticPermissionProvider(), clock: TidyClock = SystemClock()
    ) {
        self.db = db; self.config = config; self.secrets = secrets; self.logURL = logURL
        self.permissions = permissions; self.clock = clock
    }

    public func assemble(logLines: Int = 200) -> DiagnosticsInput {
        DiagnosticsInput(
            appVersion: HostInfo.appVersion,
            osVersion: HostInfo.osVersion,
            deviceModel: HostInfo.deviceModel,
            generatedAt: clock.now,
            configSummary: Self.summarize(config),
            presentSecretKeys: (try? secrets.allKeys()) ?? [],
            permissions: permissions.statuses(),
            databaseSummary: (try? db.tableRowCounts()) ?? [:],
            recentLogLines: LogReader.tail(logURL, lines: logLines),
            extras: [
                "build": Self.buildConfiguration,
                "applied_migrations": (try? db.appliedMigrations().joined(separator: ",")) ?? "",
                "db_path": db.path ?? "in-memory",
                "log_path": logURL.path,
            ]
        )
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

    public static func summarize(_ c: Config) -> [String: String] {
        [
            "org_id": c.organization.productiveOrganizationId.isEmpty ? "(unset)" : c.organization.productiveOrganizationId,
            "person_id": c.organization.productivePersonId.isEmpty ? "(unset)" : c.organization.productivePersonId,
            "timezone": c.organization.timezone,
            "browser": c.capture.browser,
            "idle_threshold_s": String(c.capture.idleThresholdSeconds),
            "heartbeat_s": String(c.capture.heartbeatSeconds),
            "detour_tolerance_s": String(c.sessionization.detourToleranceSeconds),
            "increment_minutes": String(c.suggestions.incrementMinutes),
            "recap_time": c.recap.time,
            "nudges_enabled": String(c.nudges.enabled),
            "ai_enabled": String(c.ai.enabled),
            "kill_switches": "app=\(c.capture.killSwitches.appWatcher) chrome=\(c.capture.killSwitches.chrome) cal=\(c.capture.killSwitches.calendar) fathom=\(c.capture.killSwitches.fathom) slack=\(c.capture.killSwitches.slack)",
        ]
    }
}

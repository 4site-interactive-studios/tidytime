import Foundation
import TidyCore
import TidyStore
import TidyIngest

/// Runs the read-only sync engines against the live APIs. Kept separate from `AppEnvironment` so the
/// "which sources can actually run, and why not" logic is testable without touching the network.
///
/// Every source is **skippable for a stated reason** — a missing token, an unset config value, or an
/// unimplemented flow. Reporting *why* a source is idle is the whole point: a silently-zero table is
/// exactly what made the first real run confusing.
public struct IngestCoordinator: Sendable {
    private let db: AppDatabase
    private let config: Config
    private let secrets: SecretStore
    private let http: HTTPClient
    private let clock: TidyClock
    private let logger: TidyLogger?

    public init(db: AppDatabase, config: Config, secrets: SecretStore,
                http: HTTPClient = URLSessionHTTPClient(), clock: TidyClock = SystemClock(),
                logger: TidyLogger? = nil) {
        self.db = db; self.config = config; self.secrets = secrets
        self.http = http; self.clock = clock; self.logger = logger
    }

    public enum Source: String, CaseIterable, Sendable {
        case productive, fathom, slack, googleCalendar = "google_calendar"
    }

    /// Why a source did or didn't run. `.ready` means it was attempted.
    public enum Readiness: Equatable, Sendable {
        case ready
        case missingCredential(String)
        case missingConfig(String)
        case disabledByKillSwitch
        case notImplemented(String)

        public var canRun: Bool { self == .ready }
        public var explanation: String {
            switch self {
            case .ready: return "ready"
            case .missingCredential(let k): return "no credential (\(k))"
            case .missingConfig(let k): return "config \(k) is unset"
            case .disabledByKillSwitch: return "disabled by kill switch"
            case .notImplemented(let why): return "not implemented — \(why)"
            }
        }
    }

    /// Pure precondition check — no network. This is what the Doctor view shows.
    public func readiness(_ source: Source) -> Readiness {
        let k = config.capture.killSwitches
        switch source {
        case .productive:
            guard k.calendar || true else { return .disabledByKillSwitch }   // no dedicated switch
            guard has(SecretKey.productiveToken) else { return .missingCredential(SecretKey.productiveToken) }
            guard !config.organization.productiveOrganizationId.isEmpty,
                  config.organization.productiveOrganizationId != "REPLACE_WITH_ORG_ID" else {
                return .missingConfig("organization.productive_organization_id")
            }
            return .ready
        case .fathom:
            guard k.fathom else { return .disabledByKillSwitch }
            guard has(SecretKey.fathomKey) else { return .missingCredential(SecretKey.fathomKey) }
            return .ready
        case .slack:
            guard k.slack else { return .disabledByKillSwitch }
            guard has(SecretKey.slackUserToken) else { return .missingCredential(SecretKey.slackUserToken) }
            return .ready
        case .googleCalendar:
            guard k.calendar else { return .disabledByKillSwitch }
            // The client takes an injected access token; nothing produces one yet.
            return .notImplemented("OAuth sign-in flow not built (see docs/RUNNING.md)")
        }
    }

    public func readinessReport() -> [(Source, Readiness)] {
        Source.allCases.map { ($0, readiness($0)) }
    }

    private func has(_ key: String) -> Bool {
        ((try? secrets.get(key)) ?? nil)?.isEmpty == false
    }

    /// Run every ready source once. Never throws — a failing source is logged and recorded in
    /// `sync_state.last_error`, so one broken integration can't stop the others.
    public func runAll() async {
        for source in Source.allCases {
            let r = readiness(source)
            guard r.canRun else {
                logger?.debug("ingest skipped", ["source": source.rawValue, "reason": r.explanation])
                continue
            }
            do {
                try await run(source)
                logger?.info("ingest ok", ["source": source.rawValue])
            } catch {
                logger?.error("ingest failed", ["source": source.rawValue, "error": "\(error)"])
                let now = Int64(clock.now.timeIntervalSince1970)
                let prior = (try? db.syncState(source.rawValue)) ?? nil
                try? db.saveSyncState(SyncState(source: source.rawValue, cursor: prior?.cursor,
                                                lastRunAt: now, lastSuccessAt: prior?.lastSuccessAt,
                                                lastError: "\(error)"))
            }
        }
    }

    private func run(_ source: Source) async throws {
        switch source {
        case .productive:
            let token = try secrets.get(SecretKey.productiveToken) ?? ""
            guard let base = URL(string: config.productive.baseUrl) else { return }
            let builder = ProductiveRequestBuilder(baseURL: base,
                                                   organizationId: config.organization.productiveOrganizationId,
                                                   token: token)
            let client = LiveProductiveClient(http: http, builder: builder, clock: clock)
            let (after, before) = Self.dateWindow(days: 30, clock: clock, tz: timeZone)
            let personId = config.organization.productivePersonId
            try await ProductiveSync(client: client, db: db, clock: clock)
                .run(assigneeId: personId.isEmpty || personId == "resolved_at_setup" ? nil : personId,
                     after: after, before: before)

        case .fathom:
            let key = try secrets.get(SecretKey.fathomKey) ?? ""
            let client = LiveFathomClient(http: http, apiKey: key,
                                          internalDomains: config.google.internalDomains, clock: clock)
            try await FathomSync(client: client, db: db, clock: clock).run()

        case .slack:
            let token = try secrets.get(SecretKey.slackUserToken) ?? ""
            let client = LiveSlackClient(http: http, token: token)
            try await SlackSync(client: client, db: db, clock: clock).run()

        case .googleCalendar:
            return   // unreachable: readiness() reports .notImplemented
        }
    }

    var timeZone: TimeZone { TimeZone(identifier: config.organization.timezone) ?? .current }

    /// `YYYY-MM-DD` window ending today, used for the Productive time-entry pull.
    public static func dateWindow(days: Int, clock: TidyClock, tz: TimeZone) -> (String, String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = tz
        let now = clock.now
        return (f.string(from: now.addingTimeInterval(-Double(days) * 86_400)), f.string(from: now))
    }
}

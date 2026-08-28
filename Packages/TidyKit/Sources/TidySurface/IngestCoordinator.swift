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
        /// Credentials are configured but no refresh token exists yet (or it was revoked). Distinct
        /// from `missingCredential` on purpose: the fix is a **button**, not a paste — the UI shows
        /// "Sign in with Google" when it sees this case.
        case needsSignIn(String)

        public var canRun: Bool { self == .ready }
        public var explanation: String {
            switch self {
            case .ready: return "ready"
            case .missingCredential(let k): return "no credential (\(k))"
            case .missingConfig(let k): return "config \(k) is unset"
            case .disabledByKillSwitch: return "disabled by kill switch"
            case .notImplemented(let why): return "not implemented — \(why)"
            case .needsSignIn(let hint): return "needs sign-in — \(hint)"
            }
        }
    }

    /// Pure precondition check — no network. This is what the Doctor view shows.
    public func readiness(_ source: Source) -> Readiness {
        let k = config.capture.killSwitches
        switch source {
        case .productive:
            // No dedicated kill switch for Productive in v1 (it's the product's whole point).
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
            guard !config.google.clientId.isEmpty else { return .missingConfig("google.client_id") }
            // The client secret is needed by BOTH the sign-in and every refresh exchange — fail
            // fast with the row that points at the right paste field.
            guard has(SecretKey.googleClientSecret) else {
                return .missingCredential(SecretKey.googleClientSecret)
            }
            guard has(SecretKey.googleRefreshToken) else {
                return .needsSignIn("click Sign in with Google in Settings → Credentials")
            }
            return .ready
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
            // Snapshot secret values BEFORE running: a failure path may DELETE a secret (e.g. a
            // rejected refresh token) before we get here, and an error message can still echo the
            // deleted value — computing the redaction list afterward would miss it (caught by
            // LastErrorRedactionTests).
            let known = SecretKey.all.compactMap { (try? secrets.get($0)) ?? nil }
            do {
                try await run(source)
                logger?.info("ingest ok", ["source": source.rawValue])
            } catch {
                // last_error surfaces in Doctor and the diagnostics bundle, and provider error
                // bodies can echo request material — redact before persisting (round-3 R3-2,
                // G6 defense-in-depth). The logger redacts on its own already.
                let safeError = Redactor.redact("\(error)", secrets: known)
                logger?.error("ingest failed", ["source": source.rawValue, "error": safeError])
                let now = Int64(clock.now.timeIntervalSince1970)
                let prior = (try? db.syncState(source.rawValue)) ?? nil
                try? db.saveSyncState(SyncState(source: source.rawValue, cursor: prior?.cursor,
                                                lastRunAt: now, lastSuccessAt: prior?.lastSuccessAt,
                                                lastError: safeError))
            }
        }
    }

    private func run(_ source: Source) async throws {
        switch source {
        case .productive:
            let token = try secrets.get(SecretKey.productiveToken) ?? ""
            guard let base = URL(string: config.productive.baseUrl) else {
                // A malformed base URL used to silently no-op; throw so it lands in
                // sync_state.last_error and Doctor can explain it (round-3 R1-C8).
                throw TidyError.config("productive.base_url is not a valid URL: \(config.productive.baseUrl)")
            }
            let builder = ProductiveRequestBuilder(baseURL: base,
                                                   organizationId: config.organization.productiveOrganizationId,
                                                   token: token)
            let client = LiveProductiveClient(http: http, builder: builder, clock: clock, logger: logger)
            let (after, before) = Self.dateWindow(days: 30, clock: clock, tz: timeZone)
            let personId = config.organization.productivePersonId
            // selfEmail was never passed, so `selfId` was always nil — which silently meant
            // "fetch every task in the org" and "never fetch time entries at all".
            let selfEmail = config.organization.productiveSelfEmail
            try await ProductiveSync(client: client, db: db, clock: clock,
                                     selfEmail: selfEmail.isEmpty ? nil : selfEmail)
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
            try await SlackSync(client: client, db: db, clock: clock, logger: logger).run()

        case .googleCalendar:
            let oauth = GoogleOAuthConfig(
                clientId: config.google.clientId,
                clientSecret: (try? secrets.get(SecretKey.googleClientSecret)) ?? nil,
                scopes: config.google.scopes)
            let provider = GoogleTokenProvider(config: oauth, http: http, secrets: secrets, clock: clock)
            let client = LiveGoogleCalendarClient(http: http,
                                                  internalDomains: config.google.internalDomains,
                                                  accessToken: provider.tokenClosure(), clock: clock)
            let (timeMin, timeMax) = Self.calendarWindow(daysBack: 30, daysForward: 60, clock: clock)
            let sync = CalendarSync(client: client, db: db, clock: clock,
                                    calendarId: config.google.calendarId)
            do {
                try await sync.run(timeMin: timeMin, timeMax: timeMax)
            } catch let error as GoogleOAuthError {
                // A rejected refresh token is terminal for that token: delete it so readiness flips
                // to .needsSignIn and the UI shows the sign-in button instead of a permanent error.
                if case .refreshRejected = error { try? secrets.delete(SecretKey.googleRefreshToken) }
                throw error   // runAll records it in sync_state.last_error either way
            } catch IngestError.http(410, _) {
                // Google returns 410 GONE for an expired syncToken. Without clearing the cursor
                // this would fail identically forever (round-3 R1-C7): reset and do one full
                // re-window fetch.
                try db.saveSyncState(SyncState(source: "google_calendar", cursor: nil,
                                               lastRunAt: Int64(clock.now.timeIntervalSince1970)))
                try await sync.run(timeMin: timeMin, timeMax: timeMax)
            }
        }
    }

    var timeZone: TimeZone { TimeZone(identifier: config.organization.timezone) ?? .current }

    /// `YYYY-MM-DD` window ending today, used for the Productive time-entry pull.
    public static func dateWindow(days: Int, clock: TidyClock, tz: TimeZone) -> (String, String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = tz
        let now = clock.now
        return (f.string(from: now.addingTimeInterval(-Double(days) * 86_400)), f.string(from: now))
    }

    /// RFC 3339 UTC window for the FIRST calendar sync — past for meeting backfill, future for
    /// nudge-suppression windows. Ignored by the client once a syncToken cursor exists.
    public static func calendarWindow(daysBack: Int, daysForward: Int, clock: TidyClock) -> (String, String) {
        let f = ISO8601DateFormatter()
        return (f.string(from: clock.now.addingTimeInterval(-Double(daysBack) * 86_400)),
                f.string(from: clock.now.addingTimeInterval(Double(daysForward) * 86_400)))
    }
}

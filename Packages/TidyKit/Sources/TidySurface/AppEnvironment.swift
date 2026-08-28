import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
import TidyCore
import TidyStore
import TidyCapture
import TidyIngest
import TidyUnderstand
import TidySuggest
import TidyAI

/// The dependency container the app shell owns: opens the database (running migrations), loads
/// config, wires the Keychain secret store and file logger, and drives the periodic jobs.
///
/// Lives in `TidySurface` (not `App/`) so it is inside the SwiftPM package and can be compiled and
/// — where it is pure logic — tested. The app target stays a thin `@main` that constructs this.
@MainActor
public final class AppEnvironment: ObservableObject {
    public let paths: AppPaths
    public let config: Config
    public let db: AppDatabase
    public let secrets: SecretStore
    public let logger: TidyLogger

    /// nil when the database could not be opened — the UI shows the failure instead of pretending.
    public private(set) var startupError: String?

    @Published public private(set) var isCapturing = false
    @Published public private(set) var status: Status = .idle
    @Published public private(set) var today: RecapDay?

    public enum Status: Equatable, Sendable {
        case idle, capturing, paused, attention(String)
    }

    #if canImport(AppKit)
    private var captureController: LiveCaptureController?
    #endif
    private var jobTimer: Timer?
    private var ingestTimer: Timer?
    /// Why each ingest source is or isn't running — surfaced in Doctor so a zero table is explained.
    @Published public private(set) var ingestReadiness: [(IngestCoordinator.Source, IngestCoordinator.Readiness)] = []

    public enum GoogleSignInState: Equatable, Sendable {
        case idle, inProgress, succeeded, failed(String)
    }
    /// Drives the Sign in with Google button + its status caption. A `.failed` sticks until the
    /// next attempt — unlike a transient save note, an error should not evaporate unread.
    @Published public private(set) var googleSignIn: GoogleSignInState = .idle

    public var ingest: IngestCoordinator {
        IngestCoordinator(db: db, config: config, secrets: secrets, clock: SystemClock(), logger: logger)
    }

    /// Run the Google OAuth loopback flow: opens the default browser for consent, captures the
    /// redirect locally, stores the refresh token in the Keychain, then kicks a first sync.
    public func signInWithGoogle() {
        guard googleSignIn != .inProgress else { return }
        guard !config.google.clientId.isEmpty else {
            googleSignIn = .failed("google.client_id is not set in config.json — see the instructions above")
            return
        }
        googleSignIn = .inProgress
        let oauth = GoogleOAuthConfig(
            clientId: config.google.clientId,
            clientSecret: (try? secrets.get(SecretKey.googleClientSecret)) ?? nil,
            scopes: config.google.scopes)
        #if canImport(AppKit)
        let opener: GoogleAuthenticator.Opener = { url in
            DispatchQueue.main.async { _ = NSWorkspace.shared.open(url) }
        }
        #else
        let opener: GoogleAuthenticator.Opener = { _ in }
        #endif
        let authenticator = GoogleAuthenticator(config: oauth, http: URLSessionHTTPClient(),
                                                secrets: secrets, opener: opener)
        let log = logger
        Task { @MainActor in
            do {
                _ = try await authenticator.signIn()
                log.info("google sign-in succeeded", [:])
                googleSignIn = .succeeded
                runIngestOnce()   // first calendar sync + refreshes ingestReadiness
            } catch {
                let message = (error as? GoogleOAuthError)?.description ?? "\(error)"
                log.error("google sign-in failed", ["error": message])
                googleSignIn = .failed(message)
                ingestReadiness = ingest.readinessReport()
            }
        }
    }

    // MARK: Init

    /// Production init. Throws only if the support directory or DB is unusable — the caller shows
    /// the error rather than launching a half-working app.
    public init(paths: AppPaths? = nil) throws {
        let resolved = try (paths ?? AppPaths.standard()).ensureDirectories()
        self.paths = resolved
        // Give a fresh install the config file that Doctor, Settings, and permissions-setup.md all
        // tell the user to open. Kept out of `ensureDirectories()`, whose contract is filesystem
        // layout, not content — the doctor CLI resolves the same paths and must never mutate the
        // support directory as a side effect. Never overwrites; failure is non-fatal.
        let seeded = ConfigSeeder().seedIfMissing(at: resolved.configURL)
        self.config = ConfigLoader().loadOrDefault(from: resolved.configURL)
        self.db = try AppDatabase.open(at: resolved.databaseURL)
        let store = KeychainSecretStore()
        self.secrets = store
        let sink: LogSink = (try? FileLogSink(url: resolved.currentLogURL)) ?? InMemoryLogSink()
        // Exact-value redaction needs the actual secret strings; read them once and cache — the
        // logger consults this closure per record (round-3 R3-3: pattern redaction alone misses
        // secrets that don't match a known token shape).
        let cachedSecrets: [String] = SecretKey.all.compactMap { (try? store.get($0)) ?? nil }
        self.logger = TidyLogger(category: "app", sink: sink, secrets: { cachedSecrets })
        _ = try? db.installId()
        // Stamp provenance into the database and the very first log line of every launch. Today's
        // confusion — a stale copy in the Trash still being launched by a leftover login item,
        // while /Applications held the current build — was invisible precisely because neither the
        // log nor the database said which binary was talking.
        let build = BuildInfo.current()
        db.recordRunningBuild(build)
        logger.info("environment ready", [
            "db": resolved.databaseURL.lastPathComponent,
            "config": seeded.logValue,
            "version": build.version,
            "git_sha": build.gitSHA,
            "built_at": build.builtAt,
            "bundle_path": build.bundlePath,
        ])
    }

    /// Test/preview init from an already-open database.
    public init(db: AppDatabase, config: Config = Config(), paths: AppPaths,
                secrets: SecretStore = InMemorySecretStore(), logger: TidyLogger? = nil) {
        self.paths = paths; self.config = config; self.db = db; self.secrets = secrets
        self.logger = logger ?? TidyLogger(category: "app", sink: InMemoryLogSink())
    }

    // MARK: Capture lifecycle

    public func startCapture() {
        guard config.capture.killSwitches.appWatcher else {
            logger.info("capture disabled by kill switch"); status = .paused; return
        }
        #if canImport(AppKit)
        if captureController == nil {
            captureController = LiveCaptureController(db: db, config: config)
        }
        captureController?.start()
        #endif
        isCapturing = true
        status = .capturing
        startPeriodicJobs()
        logger.info("capture started")
    }

    public func pauseCapture() {
        #if canImport(AppKit)
        captureController?.stop()
        #endif
        jobTimer?.invalidate(); jobTimer = nil
        ingestTimer?.invalidate(); ingestTimer = nil
        isCapturing = false
        status = .paused
        logger.info("capture paused")
    }

    public func toggleCapture() { isCapturing ? pauseCapture() : startCapture() }

    // MARK: Periodic work

    /// Sessionize + classify + roll up on a slow cadence. Kept coarse deliberately: these are
    /// batch operations over already-captured rows, not part of the capture hot path.
    private func startPeriodicJobs() {
        jobTimer?.invalidate()
        jobTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runPipelineOnce() }
        }
        runPipelineOnce()

        // Ingest runs on its own, slower cadence and never blocks capture.
        ingestReadiness = ingest.readinessReport()
        ingestTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runIngestOnce() }
        }
        runIngestOnce()
    }

    /// Kick every ready ingest source once. Safe to call from a button.
    /// True while an ingest pass is executing. A Slack first sync can legitimately outlive the
    /// 900s timer (Retry-After sleeps × pages × conversations), and overlapping runs interleave
    /// each conversation's delete+rebuild non-transactionally — producing duplicate slack sessions
    /// — while doubling traffic against the very rate limits the sync respects (round-3 R1-C1).
    @Published public private(set) var ingestInFlight = false

    public func runIngestOnce() {
        guard !ingestInFlight else {
            logger.debug("ingest skipped", ["reason": "a run is already in flight"])
            return
        }
        ingestInFlight = true
        let coordinator = ingest
        Task { @MainActor in
            defer { ingestInFlight = false }
            await coordinator.runAll()
            self.ingestReadiness = coordinator.readinessReport()
            try? self.refreshToday()
        }
    }

    /// One pass of the local (non-network, non-cloud) pipeline. Safe to call repeatedly.
    public func runPipelineOnce() {
        do {
            let (from, to) = Self.dayBounds(for: Date(), timeZone: timeZone)
            let builder = SessionBuildJob(
                sessionizer: Sessionizer(detourTolerance: config.sessionization.detourToleranceSeconds,
                                         minSessionSeconds: config.sessionization.minSessionSeconds),
                separateChatsByPath: config.capture.separateChatsByPath)
            try builder.rebuild(db, from: from, to: to, now: Int64(Date().timeIntervalSince1970))
            // Vocabulary before classification: rung 1 matches against `entity_signals`, and until
            // this call existed that table had 0 rows — so rung 1 could never fire and only rung 2
            // lexical matching ever produced an attribution (15 of 3,890 sessions). Idempotent and
            // cheap; `insertSignalIfAbsent` never overwrites a user-confirmed rule.
            _ = try EntityBootstrap().run(db, now: Int64(Date().timeIntervalSince1970))
            _ = try DayClassifier().run(db, from: from, to: to, now: Int64(Date().timeIntervalSince1970))
            try refreshToday()
            try writeRollups()
            try RetentionJob().purge(db, retentionDays: config.retentionDays, now: Date())
            writeDiagnosticsSnapshot()
        } catch {
            logger.error("pipeline pass failed", ["error": "\(error)"])
            status = .attention("pipeline error")
        }
    }

    /// Persist the daily rollup — the dashboard's and the context-switching metrics' only source.
    ///
    /// `RecapAssembler.writeRollup` is the sole writer of `daily_rollups`, and until this call site
    /// existed its only callers in the entire tree were three unit tests. The metrics shipped in
    /// `bf5463f` computed correctly and were persisted by nobody, so the table sat at 0 rows while
    /// 3,669 sessions accumulated. Nothing surfaced it, because a job that is never invoked cannot
    /// log a failure.
    ///
    /// Yesterday is re-rolled alongside today because the pipeline timer only ever knows about the
    /// current day: whatever the last pass before midnight computed would otherwise be frozen as
    /// yesterday's permanent record, missing its final minutes. Re-rolling is idempotent —
    /// `upsertRollup` keys on the day.
    private func writeRollups() throws {
        let assembler = RecapAssembler(db: db, config: config,
                                       selfPersonId: (try? db.selfPerson())?.id)
        for daysAgo in 0...1 {
            let date = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
            let (from, to) = Self.dayBounds(for: date, timeZone: timeZone)
            _ = try assembler.writeRollup(day: Self.dayString(date, timeZone), from: from, to: to)
        }
    }

    public func refreshToday() throws {
        let (from, to) = Self.dayBounds(for: Date(), timeZone: timeZone)
        let assembler = RecapAssembler(db: db, config: config,
                                       selfPersonId: (try? db.selfPerson())?.id)
        today = try assembler.assemble(day: Self.dayString(Date(), timeZone), from: from, to: to)
    }

    // MARK: Helpers

    public var timeZone: TimeZone { TimeZone(identifier: config.organization.timezone) ?? .current }

    /// Pure helpers — `nonisolated` so they're callable (and testable) off the main actor.
    public nonisolated static func dayString(_ date: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"; f.timeZone = tz
        return f.string(from: date)
    }

    /// Local-day bounds as epoch seconds.
    public nonisolated static func dayBounds(for date: Date, timeZone: TimeZone) -> (Int64, Int64) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (Int64(start.timeIntervalSince1970), Int64(end.timeIntervalSince1970))
    }

    /// Write the redacted bundle to `paths.diagnosticsURL` so tooling (and an AI assistant) can read
    /// current app state — including THIS PROCESS's TCC status, which an out-of-process CLI cannot
    /// observe — without anyone clicking a button.
    @discardableResult
    public func writeDiagnosticsSnapshot() -> URL? {
        let assembler = DiagnosticsAssembler(
            db: db, config: config, secrets: secrets, logURL: paths.currentLogURL,
            permissions: PermissionInspector())
        var input = assembler.assemble()
        input.extras["snapshot_written_at"] = ISO8601DateFormatter().string(from: Date())
        input.extras["capturing"] = String(isCapturing)
        for (source, readiness) in ingestReadiness {
            input.extras["ingest.\(source.rawValue)"] = readiness.explanation
        }
        let known = SecretKey.all.compactMap { try? secrets.get($0) }.compactMap { $0 }
        let text = DiagnosticsBundle.render(input, secrets: known)
        do {
            try text.write(to: paths.diagnosticsURL, atomically: true, encoding: .utf8)
            return paths.diagnosticsURL
        } catch {
            logger.error("diagnostics snapshot failed", ["error": "\(error)"])
            return nil
        }
    }

    /// Assemble + copy the redacted diagnostic bundle (manual debug mode).
    public func copyDiagnostics(using clipboard: ClipboardWriter = SystemClipboard()) {
        let assembler = DiagnosticsAssembler(
            db: db, config: config, secrets: secrets, logURL: paths.currentLogURL,
            permissions: PermissionInspector())
        let known = SecretKey.all.compactMap { try? secrets.get($0) }.compactMap { $0 }
        assembler.copyDiagnostics(using: clipboard, knownSecretValues: known)
        logger.info("diagnostics copied to clipboard")
    }
}

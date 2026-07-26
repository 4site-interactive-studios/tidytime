import Foundation
import SwiftUI
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

    public var ingest: IngestCoordinator {
        IngestCoordinator(db: db, config: config, secrets: secrets, clock: SystemClock(), logger: logger)
    }

    // MARK: Init

    /// Production init. Throws only if the support directory or DB is unusable — the caller shows
    /// the error rather than launching a half-working app.
    public init(paths: AppPaths? = nil) throws {
        let resolved = try (paths ?? AppPaths.standard()).ensureDirectories()
        self.paths = resolved
        self.config = ConfigLoader().loadOrDefault(from: resolved.configURL)
        self.db = try AppDatabase.open(at: resolved.databaseURL)
        self.secrets = KeychainSecretStore()
        let sink: LogSink = (try? FileLogSink(url: resolved.currentLogURL)) ?? InMemoryLogSink()
        self.logger = TidyLogger(category: "app", sink: sink)
        _ = try? db.installId()
        logger.info("environment ready", ["db": resolved.databaseURL.lastPathComponent])
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
    public func runIngestOnce() {
        let coordinator = ingest
        Task { @MainActor in
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
            _ = try DayClassifier().run(db, from: from, to: to, now: Int64(Date().timeIntervalSince1970))
            try refreshToday()
            try RetentionJob().purge(db, retentionDays: config.retentionDays, now: Date())
        } catch {
            logger.error("pipeline pass failed", ["error": "\(error)"])
            status = .attention("pipeline error")
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

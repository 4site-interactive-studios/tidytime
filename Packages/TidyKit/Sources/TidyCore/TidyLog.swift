import Foundation
import os

/// Structured logging. Every log line goes to two places:
///  1. Apple's unified logging (`os.Logger`) for live `Console.app` / `log stream` viewing.
///  2. A JSONL file (one JSON object per line) that AI tooling can read now and later for
///     troubleshooting (guardrail-friendly: secrets are redacted before write — G6).
///
/// The logger is a Sendable value type; sinks are injected so tests capture records in memory.

public enum LogLevel: String, Sendable, Codable, Comparable, CaseIterable {
    case debug, info, warn, error
    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (l: LogLevel, r: LogLevel) -> Bool { l.rank < r.rank }
}

/// One structured log line.
public struct LogRecord: Sendable, Codable, Equatable {
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let message: String
    public let fields: [String: String]
    public init(timestamp: Date, level: LogLevel, category: String, message: String, fields: [String: String]) {
        self.timestamp = timestamp; self.level = level; self.category = category
        self.message = message; self.fields = fields
    }
}

public protocol LogSink: Sendable {
    func write(_ record: LogRecord)
}

/// Appends JSONL to a file, with size-based rotation to `<name>.1`. Never throws to callers —
/// logging must not crash the app.
public final class FileLogSink: LogSink, @unchecked Sendable {
    private let url: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "com.4site.TidyTime.log")
    private let encoder: JSONEncoder

    public init(url: URL, maxBytes: Int = 5_000_000) throws {
        self.url = url
        self.maxBytes = maxBytes
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = enc
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    public func write(_ record: LogRecord) {
        queue.sync {
            do {
                rotateIfNeeded()
                var line = try encoder.encode(record)
                line.append(0x0A)
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                // Swallow: a failed log write must never take down the process.
            }
        }
    }

    private func rotateIfNeeded() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        guard size >= maxBytes else { return }
        let rolled = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rolled)
        try? FileManager.default.moveItem(at: url, to: rolled)
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
}

/// Captures records in memory for tests.
public final class InMemoryLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [LogRecord] = []
    public init() {}
    public func write(_ record: LogRecord) {
        lock.lock(); defer { lock.unlock() }; _records.append(record)
    }
    public var records: [LogRecord] {
        lock.lock(); defer { lock.unlock() }; return _records
    }
}

/// Fans out to multiple sinks (e.g. file + in-memory in a debug session).
public struct MultiLogSink: LogSink {
    private let sinks: [LogSink]
    public init(_ sinks: [LogSink]) { self.sinks = sinks }
    public func write(_ record: LogRecord) { for s in sinks { s.write(record) } }
}

/// The injectable logger. Create one per subsystem area (`category`); share the same `sink`.
public struct TidyLogger: Sendable {
    public let category: String
    public let minLevel: LogLevel
    private let sink: LogSink
    private let osLogger: os.Logger
    private let clock: TidyClock
    private let secrets: @Sendable () -> [String]

    public init(
        category: String,
        sink: LogSink,
        clock: TidyClock = SystemClock(),
        minLevel: LogLevel = .debug,
        subsystem: String = TidyTime.bundleIdentifier,
        secrets: @escaping @Sendable () -> [String] = { [] }
    ) {
        self.category = category
        self.sink = sink
        self.clock = clock
        self.minLevel = minLevel
        self.osLogger = os.Logger(subsystem: subsystem, category: category)
        self.secrets = secrets
    }

    /// Return a logger for a different category sharing this one's sink/clock/redaction.
    public func scoped(_ category: String) -> TidyLogger {
        TidyLogger(category: category, sink: sink, clock: clock, minLevel: minLevel, secrets: secrets)
    }

    public func debug(_ m: String, _ f: [String: String] = [:]) { log(.debug, m, f) }
    public func info(_ m: String, _ f: [String: String] = [:]) { log(.info, m, f) }
    public func warn(_ m: String, _ f: [String: String] = [:]) { log(.warn, m, f) }
    public func error(_ m: String, _ f: [String: String] = [:]) { log(.error, m, f) }

    public func log(_ level: LogLevel, _ message: String, _ fields: [String: String] = [:]) {
        guard level >= minLevel else { return }
        let known = secrets()
        let safeMessage = Redactor.redact(message, secrets: known)
        let safeFields = fields.mapValues { Redactor.redact($0, secrets: known) }
        let record = LogRecord(timestamp: clock.now, level: level, category: category,
                               message: safeMessage, fields: safeFields)
        sink.write(record)
        let rendered = safeFields.isEmpty ? safeMessage
            : "\(safeMessage) | " + safeFields.map { "\($0)=\($1)" }.sorted().joined(separator: " ")
        switch level {
        case .debug: osLogger.debug("\(rendered, privacy: .public)")
        case .info: osLogger.info("\(rendered, privacy: .public)")
        case .warn: osLogger.warning("\(rendered, privacy: .public)")
        case .error: osLogger.error("\(rendered, privacy: .public)")
        }
    }
}

/// Reads back the tail of a JSONL log file for diagnostics / AI troubleshooting.
public enum LogReader {
    public static func tail(_ url: URL, lines: Int) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let all = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Array(all.suffix(lines))
    }
}

import Foundation

/// Resolves the on-disk locations TidyTime uses. Injectable so tests point at a temp directory
/// instead of the real `~/Library/Application Support/TidyTime`.
public struct AppPaths: Sendable, Equatable {
    /// Root: `~/Library/Application Support/TidyTime` in production; a temp dir in tests.
    public let supportDirectory: URL

    public init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    /// Production paths under the user's Application Support directory.
    public static func standard(
        appName: String = TidyTime.appName,
        fileManager: FileManager = .default
    ) throws -> AppPaths {
        let base = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return AppPaths(supportDirectory: base.appendingPathComponent(appName, isDirectory: true))
    }

    public var databaseURL: URL { supportDirectory.appendingPathComponent("tidytime.sqlite") }
    public var logsDirectory: URL { supportDirectory.appendingPathComponent("logs", isDirectory: true) }
    public var currentLogURL: URL { logsDirectory.appendingPathComponent("tidytime.jsonl") }
    public var configURL: URL { supportDirectory.appendingPathComponent("config.json") }
    /// Latest rendered diagnostic bundle, written by the running app. Readable by tooling (and by
    /// an AI assistant) without a human clicking anything. Redacted like every other bundle.
    public var diagnosticsURL: URL { supportDirectory.appendingPathComponent("diagnostics.md") }

    /// Create the support + logs directories if missing. Idempotent.
    @discardableResult
    public func ensureDirectories(fileManager: FileManager = .default) throws -> AppPaths {
        for dir in [supportDirectory, logsDirectory] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return self
    }
}

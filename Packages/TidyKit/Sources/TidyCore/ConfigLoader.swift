import Foundation

/// Loads ``Config`` from a JSON file. Missing file → defaults; malformed file → a `TidyError`
/// (we do NOT silently fall back on a parse error, so a typo is surfaced, not swallowed).
public struct ConfigLoader: Sendable {
    public init() {}

    public func load(from url: URL, fileManager: FileManager = .default) throws -> Config {
        guard fileManager.fileExists(atPath: url.path) else { return Config() }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw TidyError.config("failed to parse \(url.lastPathComponent): \(error)")
        }
    }

    /// For non-critical paths where defaults are acceptable if the file is missing/unreadable.
    public func loadOrDefault(from url: URL) -> Config {
        (try? load(from: url)) ?? Config()
    }
}

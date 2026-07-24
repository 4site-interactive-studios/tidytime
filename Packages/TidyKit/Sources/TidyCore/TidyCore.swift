// TidyCore — shared foundation: config, secrets, structured logging, diagnostics, time, errors,
// and the protocol seams every other target depends on. No I/O of its own beyond files/Keychain.
// See docs/architecture/module-map.md.
import Foundation

/// Namespace + build metadata for TidyTime.
public enum TidyTime {
    /// Marketing version; keep in sync with project.yml MARKETING_VERSION.
    public static let version = "0.1.0"
    /// The Application Support subdirectory + Keychain service name.
    public static let appName = "TidyTime"
    public static let bundleIdentifier = "com.4site.TidyTime"
}

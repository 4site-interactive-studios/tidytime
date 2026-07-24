import Foundation

/// Typed errors used across TidyTime. Modules may wrap these or add their own `Error` types, but
/// these cover the cross-cutting failures. Never swallow silently (see
/// docs/conventions/error-handling-logging.md).
public enum TidyError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Config file missing/unreadable/invalid.
    case config(String)
    /// Keychain / secret storage failure.
    case secretStore(String)
    /// Database open/migration/query failure.
    case database(String)
    /// Ingest (API client / sync) failure.
    case ingest(String)
    /// Classification / suggestion pipeline failure.
    case classification(String)
    /// A guardrail invariant was violated — a bug, fail loudly (G1–G9).
    case invariant(String)

    public var description: String {
        switch self {
        case .config(let m): return "config error: \(m)"
        case .secretStore(let m): return "secret store error: \(m)"
        case .database(let m): return "database error: \(m)"
        case .ingest(let m): return "ingest error: \(m)"
        case .classification(let m): return "classification error: \(m)"
        case .invariant(let m): return "INVARIANT VIOLATION: \(m)"
        }
    }
}

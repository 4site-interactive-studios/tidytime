// TidyIngest — read-only API clients + sync engines (Productive, Fathom, Google Calendar, Slack).
// Every client is a protocol with a live (URLSession) implementation and a fake, so sync/parse
// logic is tested with recorded fixtures and no live network. See docs/architecture/ingest-layer.md.
import Foundation

public enum IngestError: Error, Sendable, Equatable, CustomStringConvertible {
    case transport(String)
    case http(status: Int, body: String)
    case decoding(String)
    /// A non-GET request was attempted against a read-only API (guardrail G1).
    case readOnlyViolation(String)

    public var description: String {
        switch self {
        case .transport(let m): return "transport error: \(m)"
        case .http(let s, let b): return "http \(s): \(b)"
        case .decoding(let m): return "decoding error: \(m)"
        case .readOnlyViolation(let m): return "READ-ONLY VIOLATION: \(m)"
        }
    }
}

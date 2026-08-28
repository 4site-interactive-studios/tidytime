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
    /// A Slack `{"ok":false,"error":"…"}` body, with the **code preserved as a field**.
    ///
    /// It used to be interpolated into `.transport("slack error: \(code)")`, which made
    /// `channel_not_found` (skip this conversation), `ratelimited` (back off and retry) and
    /// `invalid_auth` (stop, the token is dead) structurally indistinguishable at every catch
    /// site. One unreachable channel therefore aborted the whole workspace sync. `method` is
    /// carried because the same code means different things per method — `not_in_channel` is
    /// documented on `conversations.history` but absent from the `conversations.replies` table.
    case slack(code: String, method: String)
    /// Retries were exhausted against a rate limit. Distinct from `.http(429, "")`, which said
    /// nothing a human could act on — it was logged 2,246 times over 33 days without once
    /// explaining what was tried or what to check.
    case rateLimited(provider: String, attempts: Int, waitedSeconds: TimeInterval, detail: String)

    public var description: String {
        switch self {
        case .transport(let m): return "transport error: \(m)"
        case .http(let s, let b): return "http \(s): \(b)"
        case .decoding(let m): return "decoding error: \(m)"
        case .readOnlyViolation(let m): return "READ-ONLY VIOLATION: \(m)"
        // Message shape kept byte-compatible with the old `.transport` rendering so existing
        // Doctor hints and log-scraping keep matching.
        case .slack(let code, let method): return "transport error: slack error: \(code) (\(method))"
        case .rateLimited(let provider, let attempts, let waited, let detail):
            return "\(provider) rate limit: still refused after \(attempts) attempts over "
                + "\(Int(waited.rounded()))s. \(detail)"
        }
    }
}

/// How to respond to a Slack error code.
///
/// Verified against Slack's live method reference on 2026-08-28 (`conversations.history`,
/// `.replies`, `.list`, `.join`, plus the rate-limit guide). The taxonomy matters because the
/// three classes need opposite handling and the previous code had only one.
public enum SlackErrorClass: Equatable, Sendable {
    /// This one conversation is unreachable; every other conversation is fine. Skip and continue.
    case skipConversation
    /// Transient or metered. Let it propagate so the run retries later with backoff.
    case retry
    /// The token, scopes, or app install is broken. Every subsequent call fails identically, so
    /// continuing burns quota and buries the real cause.
    case fatal

    /// Codes scoped to a single conversation.
    ///
    /// `channel_not_found` alone is **not** sufficient, which is the question this fix had to
    /// answer. Slack's docs make three things clear:
    /// - `not_in_channel` is documented on `conversations.history` as "The token used does not
    ///   have access to the proper channel" — membership for *this* channel, not authorization
    ///   in general.
    /// - Archiving a **public** channel drops its membership roster, so history then returns
    ///   `not_in_channel`, and `conversations.join` cannot recover because it returns
    ///   `is_archived`. Permanently unreachable, reached via a code that never mentions archiving.
    /// - `is_archived` is documented only on *mutating* methods, never on reads — Slack blocks
    ///   writes to archived channels and permits reads. It is included anyway: cheap, and the
    ///   read/write split is not guaranteed to hold.
    ///
    /// `conversation_not_found` is deliberately absent — that code does not exist in Slack's API.
    /// `channel_not_found` covers DMs and MPIMs too.
    public static let skippable: Set<String> = [
        "channel_not_found", "not_in_channel", "is_archived", "channel_is_limited_access",
        "access_denied", "no_permission", "ekm_access_denied",
        "method_not_supported_for_channel_type", "thread_not_found",
    ]

    /// Token/scope/install failures. `missing_scope` is fatal rather than skippable even though it
    /// can present per channel class (public gates on `channels:history`, private on
    /// `groups:history`): the fix is a reinstall, not a skip.
    public static let fatalCodes: Set<String> = [
        "invalid_auth", "not_authed", "account_inactive", "token_revoked", "token_expired",
        "missing_scope", "not_allowed_token_type", "team_access_not_granted",
        "two_factor_setup_required", "enterprise_is_restricted", "accesslimited",
        "deprecated_endpoint", "method_deprecated",
    ]

    /// Unknown codes classify as ``fatal`` — fail closed. A code we have never seen is more likely
    /// to be a new auth or contract problem than a per-channel quirk, and silently skipping
    /// conversations on an unrecognized error is how a sync goes quietly, permanently empty.
    public static func classify(_ code: String) -> SlackErrorClass {
        if skippable.contains(code) { return .skipConversation }
        if fatalCodes.contains(code) { return .fatal }
        if ["ratelimited", "internal_error", "fatal_error", "service_unavailable",
            "request_timeout", "team_added_to_org", "org_login_required"].contains(code) { return .retry }
        return .fatal
    }
}

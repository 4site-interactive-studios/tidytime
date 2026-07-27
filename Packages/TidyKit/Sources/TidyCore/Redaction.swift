import Foundation

/// Redacts secret material from strings before they hit logs, the outbound-payload log, or the
/// diagnostic bundle. Guardrail G6 — no secret ever reaches a file or the clipboard.
///
/// Two layers:
///  1. Exact redaction of known secret values (tokens fetched from the SecretStore).
///  2. Pattern redaction of common token shapes even when the value isn't known ahead of time.
public enum Redactor {
    /// Common secret-bearing patterns. Kept deliberately broad — over-redaction is safe.
    private static let patterns: [NSRegularExpression] = {
        let sources = [
            #"(?i)bearer\s+[A-Za-z0-9._\-]+"#,                 // Authorization: Bearer xxx
            #"xox[baprs]-[A-Za-z0-9\-]+"#,                       // Slack tokens
            #"(?i)(x-auth-token|x-api-key|api[_-]?key|authorization)\s*[:=]\s*\S+"#, // header/kv
            #"sk-[A-Za-z0-9\-]{16,}"#,                            // generic sk- keys
            #"ya29\.[A-Za-z0-9._\-]+"#,                           // Google OAuth access tokens
            #"[A-Za-z0-9._\-]+\.apps\.googleusercontent\.com"#,  // OAuth client ids
            #"1//[A-Za-z0-9._\-]+"#,                              // Google refresh tokens
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    public static let mask = "***REDACTED***"

    /// Below this length, exact-value replacement does more harm than good: a degenerate secret
    /// like "s" would replace every letter s in the text (observed mangling "sign in again" into
    /// unreadable output). Real tokens are far longer; short strings still get pattern redaction.
    public static let minimumSecretLength = 6

    /// Redact `text`: first the explicitly-known `secrets`, then pattern matches.
    public static func redact(_ text: String, secrets: [String] = []) -> String {
        var out = text
        for secret in secrets where secret.count >= minimumSecretLength {
            out = out.replacingOccurrences(of: secret, with: mask)
        }
        for regex in patterns {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: mask)
        }
        return out
    }
}

import Foundation

/// Redacts secret material from strings before they hit logs, the outbound-payload log, the
/// diagnostic bundle — and, since the 2026-09-08 audit, the database. Guardrail G6 covers
/// TidyTime's own tokens; G10 extends the same rule to *other people's* credentials that arrive
/// inside captured page text and mirrored content (a Productive task description carrying a
/// `GOCSPX-…` client secret was found live). Every free-text column ingested from an external
/// source passes through `redact` before the insert.
///
/// Two layers:
///  1. Exact redaction of known secret values (tokens fetched from the SecretStore).
///  2. Pattern redaction of common token shapes even when the value isn't known ahead of time.
public enum Redactor {
    /// Common secret-bearing patterns. Kept deliberately broad — over-redaction is safe.
    ///
    /// Each pattern names a concrete token *shape*, not a word: "token" appearing in prose must
    /// survive, `xoxp-…` must not. The `key=value` pattern at the end is the one exception, and it
    /// requires the `=` so that a sentence containing "the access token expired" is untouched.
    private static let patterns: [NSRegularExpression] = {
        let sources = [
            #"(?i)bearer\s+[A-Za-z0-9._\-]+"#,                 // Authorization: Bearer xxx
            #"xox[baprse]-[A-Za-z0-9\-]+"#,                      // Slack tokens
            #"(?i)(x-auth-token|x-api-key|api[_-]?key|authorization)\s*[:=]\s*\S+"#, // header/kv
            #"sk-[A-Za-z0-9\-]{16,}"#,                            // generic sk- keys (incl. sk-ant-…)
            #"ya29\.[A-Za-z0-9._\-]+"#,                           // Google OAuth access tokens
            #"[A-Za-z0-9._\-]+\.apps\.googleusercontent\.com"#,  // OAuth client ids
            #"1//[A-Za-z0-9._\-]+"#,                              // Google refresh tokens
            #"GOCSPX-[A-Za-z0-9_\-]{10,}"#,                        // Google OAuth client secrets
            #"AIzaSy[A-Za-z0-9_\-]{20,}"#,                         // Google API keys
            #"4/0A[A-Za-z0-9_\-]{20,}"#,                           // Google OAuth authorization codes
            #"4%2F0A[A-Za-z0-9_\-]{20,}"#,                         // …as they appear URL-encoded
            #"(?:gh[pousr]|github_pat)_[A-Za-z0-9_]{20,}"#,        // GitHub tokens
            #"fw_[A-Za-z0-9]{20,}"#,                               // Fireworks API keys
            #"eyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#, // JWTs
            #"(?i)\b(code|access_token|id_token|refresh_token|client_secret|api_key|apikey|token|secret|password)=(?!\*\*\*)[^&\s"'<>]{8,}"#, // query-style kv; never re-matches the mask
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// Literal substrings every pattern above requires (case-insensitive). A SQL `LIKE` prefilter
    /// on these lets the one-shot database scrub skip the ~93% of rows no pattern can match,
    /// instead of running sixteen regexes over every window title ever recorded.
    public static let anchors: [String] = [
        "bearer", "xox", "x-auth-token", "x-api-key", "api", "authorization", "sk-", "ya29.",
        "googleusercontent", "1//", "GOCSPX-", "AIzaSy", "4/0A", "4%2F0A", "gh", "github_pat", "fw_", "eyJ", "=",
    ]

    public static let mask = "***REDACTED***"

    /// Below this length, exact-value replacement does more harm than good: a degenerate secret
    /// like "s" would replace every letter s in the text (observed mangling "sign in again" into
    /// unreadable output). Real tokens are far longer; short strings still get pattern redaction.
    public static let minimumSecretLength = 6

    /// Redact `text`: first the explicitly-known `secrets`, then pattern matches.
    public static func redact(_ text: String, secrets: [String] = []) -> String {
        // Fast path: nothing token-shaped can hide in a short string, and this is on the capture
        // path for every window title.
        if text.utf8.count < minimumSecretLength { return text }
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

    /// `redact` for an optional column: `nil` stays `nil`.
    public static func redact(_ text: String?, secrets: [String] = []) -> String? {
        text.map { redact($0, secrets: secrets) }
    }
}

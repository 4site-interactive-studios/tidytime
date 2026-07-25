import Foundation
import TidyCore

/// Derives context keys for a sample.
///
/// Two levels, on purpose:
///  - **`derive` (coarse)** — `web:<host>` or `app:<bundleId>`. Stored in `sessions.context_key` and
///    used by the classifier's rung-1 domain/host rules (a client's site/domain resolves the same
///    regardless of which page you're on).
///  - **`grouping` (fine)** — coarse key + a normalized window/tab **title** discriminator and, when
///    `includePath` is on, the URL **path identity**. Used only to GROUP samples into sessions, so
///    switching chats/tabs *within* one app forms distinct sessions that can each attribute to a
///    different project.
///
/// All normalization primitives live in `TidyCore.ContextSignature` so capture gating, the
/// context-switch metric, and this grouping key cannot drift apart again (round-2 finding R1-1).
public enum ContextKey {
    public static func derive(isBrowser: Bool, url: String?, appBundleId: String) -> String {
        // NOTE: must use `host(from:)`, NOT `normalizedURL` — the latter falls back to the raw string
        // for unparseable input, which would yield `web:not a url` instead of the `app:` fallback.
        if isBrowser, let url, let host = ContextSignature.host(from: url) {
            return "web:" + host
        }
        return "app:" + appBundleId
    }

    /// Fine grouping key = coarse key + `#<title>[|p:<path identity>]`.
    ///
    /// Query + fragment are dropped (per-message churn must not fragment a session); allowlisted
    /// identity query keys in `policy` are retained. Native apps have no URL, so they stay
    /// title-only — two same-title native chats can't be separated without app-specific AX.
    public static func grouping(isBrowser: Bool, url: String?, appBundleId: String,
                                windowTitle: String?, includePath: Bool = true,
                                policy: ContextSignature.Policy = .default) -> String {
        let coarse = derive(isBrowser: isBrowser, url: url, appBundleId: appBundleId)
        var parts: [String] = []
        let title = ContextSignature.normalizedTitle(windowTitle)
        if !title.isEmpty { parts.append(title) }
        if includePath, isBrowser, let path = ContextSignature.pathIdentity(url, policy: policy) {
            parts.append("p:" + path)
        }
        return parts.isEmpty ? coarse : coarse + "#" + parts.joined(separator: "|")
    }

    // MARK: Forwarders (single definition lives in TidyCore.ContextSignature)

    public static func host(from url: String) -> String? { ContextSignature.host(from: url) }
    static func normalizedPath(_ url: String?) -> String? { ContextSignature.normalizedPath(url) }
    static func normalizedTitle(_ title: String?) -> String { ContextSignature.normalizedTitle(title) }
}

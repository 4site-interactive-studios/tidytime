import Foundation

/// Derives context keys for a sample.
///
/// Two levels, on purpose:
///  - **`derive` (coarse)** — `web:<host>` or `app:<bundleId>`. Stored in `sessions.context_key` and
///    used by the classifier's rung-1 domain/host rules (a client's site/domain resolves the same
///    regardless of which page you're on).
///  - **`grouping` (fine)** — coarse key + a normalized window/tab **title** discriminator. Used only
///    to GROUP samples into sessions, so switching chats/tabs *within* one app (chat 1 → Cowork →
///    chat 1 in Claude, tab → tab in Chrome) forms distinct sessions that can each attribute to a
///    different project. The window title carries the project name, so rung-2 lexical (title + page
///    text) then resolves each one.
public enum ContextKey {
    public static func derive(isBrowser: Bool, url: String?, appBundleId: String) -> String {
        if isBrowser, let url, let host = host(from: url) {
            return "web:" + host
        }
        return "app:" + appBundleId
    }

    /// Fine grouping key = coarse key + `#<title>[|p:<path>]`.
    ///
    /// When `includePath` is on (browser only), the URL **path** — where a chat/document id lives
    /// (`claude.ai/chat/<id>`) — is folded in, so two distinct chats that share the same title become
    /// separate sessions. Query + fragment are dropped, so per-*message* churn (`?msg=…`, `#anchor`)
    /// does NOT fragment the session. Native apps have no URL, so they stay title-only (two same-title
    /// native chats can't be separated without app-specific AX — a documented limit).
    public static func grouping(isBrowser: Bool, url: String?, appBundleId: String,
                                windowTitle: String?, includePath: Bool = true) -> String {
        let coarse = derive(isBrowser: isBrowser, url: url, appBundleId: appBundleId)
        var parts: [String] = []
        let title = normalizedTitle(windowTitle)
        if !title.isEmpty { parts.append(title) }
        if includePath, isBrowser, let path = normalizedPath(url) { parts.append("p:" + path) }
        return parts.isEmpty ? coarse : coarse + "#" + parts.joined(separator: "|")
    }

    /// Lowercased host of a URL, stripping a leading `www.`.
    public static func host(from url: String) -> String? {
        guard let comps = URLComponents(string: url), var host = comps.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    /// Stable per-page/per-chat identifier: the URL **path** only (query + fragment dropped, so
    /// per-message churn is ignored), lowercased, trailing slash trimmed, truncated. Root → nil.
    static func normalizedPath(_ url: String?) -> String? {
        guard let url, let comps = URLComponents(string: url) else { return nil }
        var path = comps.path.lowercased()
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty, path != "/" else { return nil }
        return String(path.prefix(120))
    }

    /// Normalize a window/tab title into a stable grouping discriminator: lowercased, leading
    /// unread-count badges like "(3) " stripped (so a changing badge doesn't fragment the session),
    /// whitespace collapsed, truncated. Kept simple — over-fineness is absorbed by pooling / ask-once.
    static func normalizedTitle(_ title: String?) -> String {
        guard let raw = title, !raw.isEmpty else { return "" }
        var t = raw.lowercased()
        if let r = t.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) { t.removeSubrange(r) }
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(t.prefix(80))
    }
}

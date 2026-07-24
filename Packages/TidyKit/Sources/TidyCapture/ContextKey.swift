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

    /// Fine grouping key = coarse key + `#<normalized title>` (omitted when the title is empty).
    public static func grouping(isBrowser: Bool, url: String?, appBundleId: String, windowTitle: String?) -> String {
        let coarse = derive(isBrowser: isBrowser, url: url, appBundleId: appBundleId)
        let discriminator = normalizedTitle(windowTitle)
        return discriminator.isEmpty ? coarse : coarse + "#" + discriminator
    }

    /// Lowercased host of a URL, stripping a leading `www.`.
    public static func host(from url: String) -> String? {
        guard let comps = URLComponents(string: url), var host = comps.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
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

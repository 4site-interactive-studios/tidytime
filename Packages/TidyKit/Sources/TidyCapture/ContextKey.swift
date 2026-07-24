import Foundation

/// Derives a normalized "context key" for a sample — the thing sessionization groups by. For a
/// browser tab it's the URL host (`web:docs.google.com`); otherwise the app bundle id
/// (`app:com.tinyspeck.slackmacgap`). Entity resolution (Phase 5) maps context keys → clients.
public enum ContextKey {
    public static func derive(isBrowser: Bool, url: String?, appBundleId: String) -> String {
        if isBrowser, let url, let host = host(from: url) {
            return "web:" + host
        }
        return "app:" + appBundleId
    }

    /// Lowercased host of a URL, stripping a leading `www.`.
    public static func host(from url: String) -> String? {
        guard let comps = URLComponents(string: url), var host = comps.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }
}

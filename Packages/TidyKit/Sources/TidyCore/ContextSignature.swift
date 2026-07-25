import Foundation

/// **The** definition of "what counts as the same context". Lives in TidyCore because all three
/// consumers must agree and they span modules that cannot import each other:
///
///  - `TidyCapture.CaptureCoordinator` — change-gates whether a new `activity_samples` row is written
///  - `TidyStore.ContextSwitchAnalyzer` — counts context switches for the recap/dashboard metric
///  - `TidyCapture.ContextKey` — builds the sessionization grouping key
///
/// Round-2 review found these had drifted into three different definitions: capture and the metric
/// keyed on the **raw** URL + title while sessionization normalized them, so per-message query churn
/// (`?msg=1` → `?msg=99`), a `#fragment`, a trailing slash, or an unread badge tick (`(3) Slack` →
/// `(4) Slack`) wrote a new sample row **and** counted as a context switch — inflating the exact
/// "how fragmented was today" number the metric exists to report. One definition, one call site.
public enum ContextSignature {
    /// What counts as *identity* inside a URL.
    ///
    /// Query parameters are dropped by default because per-message/SPA churn lives there. A
    /// **denylist** of volatile params would fail *open* (any unlisted param silently reintroduces
    /// the bug), so this is an **allowlist** that fails *closed*: empty by default (reproducing the
    /// sessionization semantics exactly), and a user whose tool carries identity in the query
    /// (`?project=acme`, `?doc=123`) opts those keys in.
    public struct Policy: Sendable, Equatable {
        public var identityQueryKeys: [String]
        public init(identityQueryKeys: [String] = []) { self.identityQueryKeys = identityQueryKeys }
        public static let `default` = Policy()
        /// Build from config so the knob is actually honored in production (round-2 finding R1-7:
        /// `separate_chats_by_path` had shipped as config nothing read outside tests).
        public init(_ capture: Config.Capture) { self.identityQueryKeys = capture.identityQueryKeys }
    }

    // MARK: URL

    /// Lowercased host, `www.` stripped. `nil` when unparseable or hostless.
    public static func host(from url: String) -> String? {
        guard let comps = URLComponents(string: url), var h = comps.host?.lowercased() else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h.isEmpty ? nil : h
    }

    /// Path only — query + fragment dropped, lowercased, trailing slashes trimmed, truncated.
    /// Root (`/`) and empty → `nil`.
    public static func normalizedPath(_ url: String?) -> String? {
        guard let url, let comps = URLComponents(string: url) else { return nil }
        var path = comps.path.lowercased()
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty, path != "/" else { return nil }
        return String(path.prefix(120))
    }

    /// Path plus any allowlisted identity query params (sorted, so ordering never matters).
    public static func pathIdentity(_ url: String?, policy: Policy = .default) -> String? {
        let path = normalizedPath(url)
        guard !policy.identityQueryKeys.isEmpty, let url,
              let comps = URLComponents(string: url), let items = comps.queryItems else { return path }
        let keep = Set(policy.identityQueryKeys.map { $0.lowercased() })
        let kept = items
            .filter { keep.contains($0.name.lowercased()) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
            .map { "\($0.name.lowercased())=\($0.value ?? "")" }
        guard !kept.isEmpty else { return path }
        let suffix = kept.joined(separator: "&")
        return (path ?? "") + "?" + suffix
    }

    /// Host (+ port) + path identity, scheme dropped (http→https is not a context switch).
    /// Falls back to the lowercased raw string when unparseable, preserving distinctness rather than
    /// collapsing every unparseable URL together.
    public static func normalizedURL(_ url: String?, policy: Policy = .default) -> String? {
        guard let url, !url.isEmpty else { return nil }
        let h = host(from: url)
        let p = pathIdentity(url, policy: policy)
        if h == nil && p == nil { return url.lowercased() }
        var out = h ?? ""
        if let port = URLComponents(string: url)?.port { out += ":\(port)" }
        out += p ?? ""
        return out.isEmpty ? url.lowercased() : out
    }

    // MARK: Title

    /// Lowercased, leading unread badge (`(3) `) stripped so a changing count doesn't read as a new
    /// context, whitespace collapsed, truncated.
    public static func normalizedTitle(_ title: String?) -> String {
        guard let raw = title, !raw.isEmpty else { return "" }
        var t = raw.lowercased()
        if let r = t.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) { t.removeSubrange(r) }
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(t.prefix(80))
    }

    // MARK: The key

    /// The canonical change key shared by capture gating and the context-switch metric.
    public static func key(appBundleId: String, windowTitle: String?, url: String?,
                           policy: Policy = .default) -> String {
        "\(appBundleId)\u{1}\(normalizedTitle(windowTitle))\u{1}\(normalizedURL(url, policy: policy) ?? "")"
    }
}

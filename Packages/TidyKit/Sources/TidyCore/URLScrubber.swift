import Foundation

/// What survives of a URL on its way into the database.
///
/// The audit of 2026-09-08 found 35 `activity_samples` rows and 4 `page_snapshots` rows whose URL
/// carried `code=` — two of them Google OAuth authorization codes — plus one carrying
/// `access_token=` / `id_token=`. `SampleRecorder` stored the URL verbatim, query string and all.
/// `CaptureExclusions` could not help because it matches on host, and the hosts were `claude.ai`
/// and `miro.com`: ordinary work sites whose sign-in redirects briefly put a credential in the
/// address bar. TidyTime's own Google sign-in does exactly the same thing at
/// `http://127.0.0.1:<port>/?code=…&state=…`.
///
/// So this runs at the capture boundary, alongside `CaptureExclusions` and for the same reason:
/// a row that should never exist must never exist. Retention deleting it in 90 days is not a fix.
///
/// The rule is an **allowlist**, not a denylist of credential-shaped parameter names. Query strings
/// are dropped entirely unless a key is in `capture.identity_query_keys` — the same knob that
/// already decides which query keys count as identity for sessionization, because "carries real
/// identity" and "safe to keep on disk" are the same judgement. A denylist (`code`, `token`, …)
/// would fail *open* on the next vendor's spelling; the allowlist fails *closed*. A short denylist
/// still exists underneath it, so that a user who allowlists `token` by mistake does not reopen
/// the hole: those keys are never stored, whatever the config says.
///
/// Fragments are dropped unconditionally — the OAuth implicit flow delivers `#access_token=…` in
/// the fragment, and nothing in this product keys on a fragment. Userinfo (`user:pass@host`) is
/// dropped for the obvious reason.
///
/// Two outcomes, because one is not enough: a loopback URL whose query or fragment carries a
/// credential-shaped key (`code`, `token`, `state`, …) is an OAuth redirect — the app's own, or
/// another local tool's — a page on screen for under a second with no attribution value. Stripping
/// it would store a harmless, useless `http://127.0.0.1:port/`; dropping the row is more honest.
/// Every other loopback URL is a local dev server and is recorded normally, query stripped like any
/// other host: `web:localhost` is real work, and the live DB held 288 loopback URLs with a query
/// string of which none was a redirect. (The first cut dropped all of them — review finding.)
public struct URLScrubber: Sendable, Equatable {
    public enum Outcome: Equatable, Sendable {
        /// Store this (possibly rewritten) URL.
        case store(String)
        /// Do not record this context at all.
        case drop
    }

    /// Query keys the user has declared to carry identity (see `Config.Capture.identityQueryKeys`).
    /// Compared case-insensitively.
    public let identityQueryKeys: Set<String>

    /// Keys that are never stored even when allowlisted. Deliberately short: the allowlist is the
    /// real guard, and this exists only so that a config mistake cannot undo it.
    public static let neverStoredKeys: Set<String> = [
        "code", "access_token", "id_token", "refresh_token", "token", "state",
        "client_secret", "api_key", "apikey", "secret", "password", "session_state",
    ]

    /// Hosts on which a credential-shaped query means "an OAuth redirect", never something worth
    /// attributing.
    public static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]", "0.0.0.0"]

    public init(identityQueryKeys: [String] = []) {
        self.identityQueryKeys = Set(identityQueryKeys.map { $0.lowercased() })
            .subtracting(Self.neverStoredKeys)
    }

    public init(_ capture: Config.Capture) { self.init(identityQueryKeys: capture.identityQueryKeys) }

    /// The URL as it may be written to disk, or `.drop`. `nil`/empty input passes through as
    /// `.store` of itself so callers need not special-case a non-browser context.
    public func scrub(_ url: String?) -> Outcome {
        guard let url, !url.isEmpty else { return .store(url ?? "") }
        guard var comps = URLComponents(string: url) else { return .store(Self.fallbackStrip(url)) }

        let host = comps.host?.lowercased() ?? ""
        if Self.loopbackHosts.contains(host), Self.carriesCredentialKey(comps) { return .drop }

        comps.fragment = nil
        comps.user = nil
        comps.password = nil

        // Filter on the percent-encoded items so an allowlisted value is stored byte-for-byte as it
        // appeared (`queryItems` would decode `%2B` to `+` and re-encode it differently).
        if let items = comps.percentEncodedQueryItems, !items.isEmpty {
            let kept = items.filter { identityQueryKeys.contains($0.name.lowercased()) }
            comps.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        } else {
            // A bare `?` with nothing after it still parses as an empty query; normalise it away.
            comps.query = nil
        }
        return .store(comps.string ?? Self.fallbackStrip(url))
    }

    /// Does the query or fragment name a key that is never stored? Fragments count because the
    /// OAuth implicit flow delivers `#access_token=…`.
    public static func carriesCredentialKey(_ comps: URLComponents) -> Bool {
        let keys = (comps.percentEncodedQueryItems ?? []).map { $0.name.lowercased() }
            + (comps.fragment ?? "").split(separator: "&").compactMap { $0.split(separator: "=").first.map { $0.lowercased() } }
        return keys.contains { Self.neverStoredKeys.contains($0) }
    }

    /// Convenience for callers that have no drop path: the stored form, or `nil` when the URL
    /// must not be recorded.
    public func stored(_ url: String?) -> String? {
        switch scrub(url) {
        case .store(let s): return s.isEmpty ? nil : s
        case .drop: return nil
        }
    }

    /// When Foundation cannot parse the URL at all, cut at the first `?` or `#`. Unparseable input
    /// is exactly the input a scrubber must not wave through.
    public static func fallbackStrip(_ url: String) -> String {
        var s = url[...]
        if let q = s.firstIndex(of: "?") { s = s[..<q] }
        if let f = s.firstIndex(of: "#") { s = s[..<f] }
        return String(s)
    }
}

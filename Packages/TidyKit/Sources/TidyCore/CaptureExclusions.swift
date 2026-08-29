import Foundation

/// What must never be written to the database at all.
///
/// The app had no exclusion mechanism of any kind. Everything the Accessibility API and the browser
/// adapter could see was recorded — a private-browsing window, a personal banking tab, a therapist's
/// portal — and the only remedy on offer was the global kill switch, which is not a remedy but an
/// off button. Retention deletes old rows; it does not help with a row that should never have
/// existed. Sensitivity gating filters what leaves the machine; it does not help either, because the
/// raw title is still on disk in `activity_samples` and still visible in the recap.
///
/// So this runs at the capture boundary, before the insert. The three rules, in order of how much
/// the user had to do to get them:
///
///  1. **Private browsing is never recorded.** No configuration, no opt-in. Opening an incognito
///     window is an unambiguous statement about being observed, and honouring it is not optional.
///  2. **Excluded hosts** — matched on registrable suffix, so `chase.com` also covers
///     `secure.chase.com`, which is the form the user will actually be looking at.
///  3. **Excluded apps** — by bundle id, for the whole-application case (a password manager, a
///     personal messages client).
///
/// A denylist normally fails open, which this codebase avoids on principle. It is the right shape
/// here anyway: the alternative is an allowlist of everything the user works on, which nobody will
/// ever complete, and an incomplete allowlist silently stops the product working. The failure this
/// design accepts is "the user must name what to exclude"; the failure it avoids is "the user must
/// name everything, forever, or get nothing."
public struct CaptureExclusions: Sendable, Equatable {
    public let hosts: [String]
    public let appBundleIds: Set<String>

    public init(hosts: [String] = [], appBundleIds: [String] = []) {
        self.hosts = hosts
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        self.appBundleIds = Set(appBundleIds.map { $0.lowercased() }.filter { !$0.isEmpty })
    }

    public init(config: Config) {
        self.init(hosts: config.capture.excludedHosts, appBundleIds: config.capture.excludedApps)
    }

    public var isEmpty: Bool { hosts.isEmpty && appBundleIds.isEmpty }

    /// Registrable-suffix match, not `contains`. `contains` would make `chase.com` also exclude
    /// `notchase.completely.example`, and a rule that silently over-excludes is as bad as one that
    /// under-excludes — it looks like the capture is broken.
    public func excludes(url: String?) -> Bool {
        guard let url, let host = Self.host(of: url)?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    public func excludes(appBundleId: String?) -> Bool {
        guard let id = appBundleId?.lowercased() else { return false }
        return appBundleIds.contains(id)
    }

    /// Accepts bare hosts as well as full URLs — a user editing config.json by hand writes
    /// `chase.com`, not `https://chase.com/`, and rejecting that would be a trap.
    public static func host(of url: String) -> String? {
        if let h = URLComponents(string: url)?.host, !h.isEmpty { return h }
        let bare = url.split(separator: "/").first.map(String.init) ?? url
        return bare.contains(".") ? bare : nil
    }
}

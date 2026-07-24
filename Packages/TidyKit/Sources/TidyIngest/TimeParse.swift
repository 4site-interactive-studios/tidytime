import Foundation

/// Small parsing helpers for ingest: RFC3339 timestamps, "HH:MM:SS" transcript offsets, email
/// domains, and internal/external classification.
public enum TimeParse {
    /// RFC3339 / ISO8601 string → Unix epoch seconds (tries fractional seconds then plain).
    public static func epoch(_ s: String?) -> Int64? {
        guard let s, !s.isEmpty else { return nil }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: s) { return Int64(d.timeIntervalSince1970) }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return Int64(d.timeIntervalSince1970) }
        return nil
    }

    /// "HH:MM:SS" / "MM:SS" / "SS" → seconds.
    public static func hmsSeconds(_ s: String?) -> Double? {
        guard let s, !s.isEmpty else { return nil }
        let parts = s.split(separator: ":").map(String.init)
        let nums = parts.compactMap(Double.init)
        guard nums.count == parts.count, !nums.isEmpty else { return nil }
        switch nums.count {
        case 3: return nums[0] * 3600 + nums[1] * 60 + nums[2]
        case 2: return nums[0] * 60 + nums[1]
        case 1: return nums[0]
        default: return nil
        }
    }

    /// Lowercased domain of an email address.
    public static func domain(_ email: String?) -> String? {
        guard let email, let at = email.firstIndex(of: "@") else { return nil }
        let d = String(email[email.index(after: at)...]).lowercased()
        return d.isEmpty ? nil : d
    }

    /// External = not one of the org's internal domains. Unknown/missing domain → external
    /// (conservative: an unknown attendee is more likely a client than a colleague).
    public static func isExternal(email: String?, internalDomains: [String]) -> Bool {
        guard let d = domain(email) else { return true }
        return !internalDomains.map { $0.lowercased() }.contains(d)
    }

    /// "YYYY-MM-DD" → Unix epoch seconds at UTC midnight (all-day events).
    public static func dayEpochUTC(_ ymd: String) -> Int64? {
        let parts = ymd.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        return cal.date(from: comps).map { Int64($0.timeIntervalSince1970) }
    }
}

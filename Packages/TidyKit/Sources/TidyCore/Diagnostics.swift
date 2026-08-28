import Foundation

/// The manual debug-mode diagnostic bundle: a single redacted, human- and AI-readable text blob a
/// tester can copy to the clipboard and paste into an AI tool that has access to the source, the
/// machine, and the logs. Contains everything useful for troubleshooting and NO secrets (G6):
/// present credentials are listed by NAME only, and the whole rendered output is passed through
/// `Redactor` as a final safety net.

public struct DiagnosticsInput: Sendable, Equatable {
    public var appVersion: String
    public var osVersion: String
    public var deviceModel: String
    public var generatedAt: Date
    /// Which commit this binary came from, when it was built, and where it lives. A bundle that
    /// only says "0.1.0" cannot tell a current install from a stale copy still being launched by a
    /// leftover login item — the exact confusion that cost a live debugging session on 2026-08-28.
    public var build: BuildInfo
    /// Non-secret config summary (e.g. org id, timezone, thresholds).
    public var configSummary: [String: String]
    /// Names of credentials present in the SecretStore — never values.
    public var presentSecretKeys: [String]
    /// Permission/TCC status, e.g. ["Accessibility": "granted", "Automation(Chrome)": "not-determined"].
    public var permissions: [String: String]
    /// Row counts per table, so state is visible without dumping user data.
    public var databaseSummary: [String: Int]
    /// Recent (already-redacted) JSONL log lines.
    public var recentLogLines: [String]
    /// Anything else worth surfacing (build config, kill-switch states…).
    public var extras: [String: String]

    public init(
        appVersion: String, osVersion: String, deviceModel: String, generatedAt: Date,
        build: BuildInfo = BuildInfo(), configSummary: [String: String] = [:],
        presentSecretKeys: [String] = [],
        permissions: [String: String] = [:], databaseSummary: [String: Int] = [:],
        recentLogLines: [String] = [], extras: [String: String] = [:]
    ) {
        self.appVersion = appVersion; self.osVersion = osVersion; self.deviceModel = deviceModel
        self.generatedAt = generatedAt; self.build = build; self.configSummary = configSummary
        self.presentSecretKeys = presentSecretKeys; self.permissions = permissions
        self.databaseSummary = databaseSummary; self.recentLogLines = recentLogLines; self.extras = extras
    }
}

public enum DiagnosticsBundle {
    /// Render the bundle as Markdown. `secrets` are extra known values to scrub (belt-and-braces on
    /// top of the pattern redactor).
    public static func render(_ input: DiagnosticsInput, secrets: [String] = []) -> String {
        let iso = ISO8601DateFormatter()
        var out = ""
        out += "# TidyTime diagnostic bundle\n\n"
        out += "_Generated \(iso.string(from: input.generatedAt)). Contains NO secrets — safe to paste into an AI assistant._\n\n"

        out += "## Environment\n"
        out += "- App version: \(input.appVersion)\n"
        // Provenance sits directly under the version, because the version alone is what misled a
        // reader before: two very different builds both call themselves 0.1.0.
        out += "- Git SHA: \(input.build.gitSHA)\n"
        out += "- Built at: \(input.build.builtAt)\n"
        out += "- Bundle path: \(input.build.bundlePath)\n"
        if !input.build.isProvenanceKnown {
            out += "  - ⚠️ This build carries no git SHA. It was not produced by `make build` /"
            out += " `make dmg`, so which commit it contains cannot be established from the binary.\n"
        }
        out += "- macOS: \(input.osVersion)\n"
        out += "- Device: \(input.deviceModel)\n\n"

        out += section("Permissions", dict: input.permissions)
        out += section("Config (non-secret)", dict: input.configSummary)

        out += "## Credentials present (names only)\n"
        if input.presentSecretKeys.isEmpty {
            out += "- (none stored)\n\n"
        } else {
            for k in input.presentSecretKeys.sorted() { out += "- \(k)\n" }
            out += "\n"
        }

        out += "## Database (row counts)\n"
        if input.databaseSummary.isEmpty {
            out += "- (no tables)\n\n"
        } else {
            for k in input.databaseSummary.keys.sorted() { out += "- \(k): \(input.databaseSummary[k]!)\n" }
            out += "\n"
        }

        out += section("Extras", dict: input.extras)

        out += "## Recent logs (\(input.recentLogLines.count) lines)\n```\n"
        out += input.recentLogLines.joined(separator: "\n")
        out += "\n```\n"

        // Final safety net: scrub the whole rendered blob.
        return Redactor.redact(out, secrets: secrets)
    }

    private static func section(_ title: String, dict: [String: String]) -> String {
        var s = "## \(title)\n"
        if dict.isEmpty {
            s += "- (none)\n\n"
        } else {
            for k in dict.keys.sorted() { s += "- \(k): \(dict[k]!)\n" }
            s += "\n"
        }
        return s
    }
}

/// Abstracts the system clipboard so the diagnostic-copy flow is testable. The AppKit-backed
/// implementation (`NSPasteboard`) lives in the app/surface layer.
public protocol ClipboardWriter: Sendable {
    func copy(_ text: String)
}

public final class FakeClipboard: ClipboardWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var _last: String?
    public init() {}
    public func copy(_ text: String) { lock.lock(); _last = text; lock.unlock() }
    public var last: String? { lock.lock(); defer { lock.unlock() }; return _last }
}

/// Best-effort host facts from Foundation only (no AppKit) so it stays in TidyCore.
public enum HostInfo {
    public static var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }
    public static var appVersion: String { TidyTime.version }
    public static var deviceModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

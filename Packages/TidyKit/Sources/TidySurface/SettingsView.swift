import SwiftUI
import TidyCore
import TidyStore

/// Settings. Config is a readable JSON file by design (PLAN §6), so this view is a **transparent
/// reader** of the live values plus the credential manager — it does not silently rewrite the file
/// behind the user's back. Secrets go to the Keychain only (G6).
public struct SettingsView: View {
    @ObservedObject var env: AppEnvironment
    @State private var presentKeys: [String] = []
    @State private var entryKey: String = SecretKey.productiveToken
    @State private var entryValue: String = ""
    @State private var savedNote: String?

    public init(env: AppEnvironment) { self.env = env }

    public var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            credentials.tabItem { Label("Credentials", systemImage: "key") }
            sensitivity.tabItem { Label("Sensitivity", systemImage: "hand.raised") }
        }
        .frame(minWidth: 560, minHeight: 460)
        .onAppear { presentKeys = (try? env.secrets.allKeys()) ?? [] }
    }

    // MARK: General (read-only view of config.json)

    private var general: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Config is a plain JSON file you can edit directly.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(env.paths.configURL.path)
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)

                group("Capture") {
                    kv("Browser", env.config.capture.browser)
                    kv("Detection poll", "\(env.config.capture.detectionIntervalSeconds)s")
                    kv("Page-text poll", "\(env.config.capture.contentIntervalSeconds)s")
                    kv("Idle threshold", "\(env.config.capture.idleThresholdSeconds)s")
                    kv("Separate chats by URL path", "\(env.config.capture.separateChatsByPath)")
                    kv("Identity query keys", env.config.capture.identityQueryKeys.isEmpty
                       ? "(none)" : env.config.capture.identityQueryKeys.joined(separator: ", "))
                }
                group("Sessionization") {
                    kv("Detour tolerance", "\(env.config.sessionization.detourToleranceSeconds)s")
                    kv("Min session", "\(env.config.sessionization.minSessionSeconds)s")
                }
                group("Suggestions") {
                    kv("Increment", "\(env.config.suggestions.incrementMinutes) min")
                    kv("Round-up bias", "\(env.config.suggestions.roundUpBias)")
                    kv("Standalone threshold", "\(env.config.suggestions.standaloneThresholdMinutes) min")
                }
                group("Recap & nudges") {
                    kv("Recap time", env.config.recap.time)
                    kv("Nudges", env.config.nudges.enabled ? "on" : "off")
                    kv("Daily cap", "\(env.config.nudges.dailyCap)")
                    kv("Quiet hours", "\(env.config.nudges.quietHours.start)–\(env.config.nudges.quietHours.end)")
                }
                group("Kill switches") {
                    let k = env.config.capture.killSwitches
                    kv("app / chrome", "\(k.appWatcher) / \(k.chrome)")
                    kv("calendar / fathom / slack", "\(k.calendar) / \(k.fathom) / \(k.slack)")
                }
                group("AI") {
                    kv("Enabled", "\(env.config.ai.enabled)")
                    ForEach(env.config.ai.routing.keys.sorted(), id: \.self) { job in
                        kv(job, env.config.ai.routing[job] ?? "—")
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: Credentials (Keychain only)

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tokens are stored in the macOS Keychain — never in config, the database, or logs (guardrail G6).")
                .font(.caption).foregroundStyle(.secondary)

            ForEach(SecretKey.all, id: \.self) { key in
                HStack {
                    Image(systemName: presentKeys.contains(key) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(presentKeys.contains(key) ? .green : .secondary)
                    Text(key).font(.system(size: 12, design: .monospaced))
                    Spacer()
                    if presentKeys.contains(key) {
                        Button("Remove") { remove(key) }.font(.caption)
                    }
                }
            }

            Divider()
            Text("Add or replace").font(.headline)
            Picker("Credential", selection: $entryKey) {
                ForEach(SecretKey.all, id: \.self) { Text($0).tag($0) }
            }
            SecureField("Paste value", text: $entryValue)
            HStack {
                Button("Save to Keychain") { save() }.disabled(entryValue.isEmpty)
                if let savedNote { Text(savedNote).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
        }
        .padding(20)
    }

    // MARK: Sensitivity

    private var sensitivity: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("The gate runs locally before anything reaches a cloud model, and fails closed — an empty list never disables it (guardrail G2).")
                    .font(.caption).foregroundStyle(.secondary)
                group("Keywords (\(env.config.sensitivity.keywords.count))") {
                    Text(env.config.sensitivity.keywords.joined(separator: ", "))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                group("Flagged people (\(env.config.sensitivity.flaggedPeople.count))") {
                    Text(env.config.sensitivity.flaggedPeople.isEmpty ? "(none)" : env.config.sensitivity.flaggedPeople.joined(separator: ", "))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                group("Flagged terms (\(env.config.sensitivity.flaggedTerms.count))") {
                    Text(env.config.sensitivity.flaggedTerms.isEmpty ? "(none)" : env.config.sensitivity.flaggedTerms.joined(separator: ", "))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text("Edit these lists in config.json; a built-in floor list applies regardless.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    // MARK: actions

    private func save() {
        do {
            try env.secrets.set(entryKey, entryValue)
            entryValue = ""
            presentKeys = (try? env.secrets.allKeys()) ?? []
            savedNote = "Saved."
        } catch {
            savedNote = "Failed: \(error)"
        }
    }

    private func remove(_ key: String) {
        try? env.secrets.delete(key)
        presentKeys = (try? env.secrets.allKeys()) ?? []
    }

    @ViewBuilder private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            content()
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.system(size: 12, design: .monospaced))
        }
    }
}

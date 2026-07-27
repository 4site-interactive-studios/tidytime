import SwiftUI
import TidyCore
import TidyStore

/// Settings. Config is a readable JSON file by design (PLAN §6), so this view is a **transparent
/// reader** of the live values plus the credential manager — it does not silently rewrite the file
/// behind the user's back. Secrets go to the Keychain only (G6).
public struct SettingsView: View {
    @ObservedObject var env: AppEnvironment
    @State private var presentKeys: [String] = []
    @State private var entryKey: String = ""
    @State private var entryValue: String = ""
    @State private var savedNote: String?
    /// Set when the user clicks Remove — drives the confirmation dialog.
    @State private var pendingRemoval: CredentialInfo?

    public init(env: AppEnvironment) { self.env = env }

    public var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            credentials.tabItem { Label("Credentials", systemImage: "key") }
            sensitivity.tabItem { Label("Sensitivity", systemImage: "hand.raised") }
        }
        .frame(minWidth: 560, minHeight: 460)
        .onAppear {
            refreshKeys()
            // Start the picker on the first key that can actually be pasted (the old hardcoded
            // productive.token broke as soon as that key was set).
            entryKey = CredentialCatalog.pickerChoices(present: presentKeys).first ?? ""
        }
    }

    private func refreshKeys() {
        presentKeys = (try? env.secrets.allKeys()) ?? []
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Tokens are stored in the macOS Keychain — never in config, the database, or logs (guardrail G6). Each row explains how to get its key, in plain language.")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(CredentialCatalog.all) { info in
                    credentialRow(info)
                }

                Divider()
                addSection
                googleSection
            }
            .padding(20)
        }
        .confirmationDialog(
            pendingRemoval.map { removalTitle($0) } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil },
                                 set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            if let info = pendingRemoval {
                Button(info.key == SecretKey.googleRefreshToken ? "Sign out" : "Remove",
                       role: .destructive) {
                    remove(info.key)
                    pendingRemoval = nil
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            }
        } message: {
            Text("TidyTime will stop syncing this source until you set it up again. The instructions stay right here.")
        }
        .onChange(of: env.googleSignIn) { _, state in
            // A completed sign-in writes the refresh token programmatically — reflect it.
            if state == .succeeded { refreshKeys() }
        }
    }

    @ViewBuilder private func credentialRow(_ info: CredentialInfo) -> some View {
        let isSet = presentKeys.contains(info.key)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: isSet ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSet ? .green : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.displayName).font(.system(size: 13, weight: .medium))
                    Text(info.key).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                if isSet {
                    Button(info.key == SecretKey.googleRefreshToken ? "Sign out" : "Remove…") {
                        pendingRemoval = info
                    }
                    .font(.caption)
                }
            }
            Text(info.purpose).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isSet {
                if info.pastable {
                    Text("To change this key, remove it first — that's on purpose, so it can't be overwritten by accident.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(info.steps.enumerated()), id: \.offset) { i, step in
                            Text("\(i + 1). \(step)")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        ForEach(info.links, id: \.title) { link in
                            Link(link.title, destination: link.url).font(.caption)
                        }
                    }
                    .padding(.top, 2)
                } label: {
                    Text("How to get this").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 2)
    }

    /// The paste form. Lock-once-set lives in `CredentialCatalog.pickerChoices`: a stored key
    /// simply never reappears here until it's removed.
    @ViewBuilder private var addSection: some View {
        let choices = CredentialCatalog.pickerChoices(present: presentKeys)
        if choices.isEmpty {
            Label("Everything is set up ✓", systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.green)
        } else {
            Text("Add a key").font(.headline)
            Picker("Credential", selection: $entryKey) {
                ForEach(choices, id: \.self) { key in
                    Text(CredentialCatalog.info(for: key)?.displayName ?? key).tag(key)
                }
            }
            SecureField("Paste value", text: $entryValue)
            HStack {
                Button("Save to Keychain") { save() }.disabled(entryValue.isEmpty)
                if let savedNote { Text(savedNote).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    /// Sign in with Google — enabled once the client id (config) and client secret (above) exist.
    @ViewBuilder private var googleSection: some View {
        Divider()
        Text("Google Calendar").font(.headline)
        let missingClientId = env.config.google.clientId.isEmpty
        let missingSecret = !presentKeys.contains(SecretKey.googleClientSecret)
        HStack(spacing: 8) {
            Button("Sign in with Google") { env.signInWithGoogle() }
                .disabled(missingClientId || missingSecret || env.googleSignIn == .inProgress)
            switch env.googleSignIn {
            case .idle: EmptyView()
            case .inProgress: Text("Check your browser…").font(.caption).foregroundStyle(.secondary)
            case .succeeded: Text("Signed in ✓").font(.caption).foregroundStyle(.green)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if missingClientId {
            Text("First: put your Google Client ID in the settings file — see the “Google client secret” instructions above.")
                .font(.caption).foregroundStyle(.secondary)
        } else if missingSecret {
            Text("First: paste the Google client secret above.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func removalTitle(_ info: CredentialInfo) -> String {
        info.key == SecretKey.googleRefreshToken
            ? "Sign out of Google?" : "Remove \(info.displayName)?"
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
            let saved = entryKey
            try env.secrets.set(saved, entryValue)
            entryValue = ""
            savedNote = "Saved."
            // The saved key just became locked — advance the picker to the next open slot.
            entryKey = CredentialCatalog.nextSelection(afterSaving: saved, present: presentKeys) ?? ""
            refreshKeys()
        } catch {
            savedNote = "Failed: \(error)"
        }
    }

    private func remove(_ key: String) {
        do {
            try env.secrets.delete(key)
        } catch {
            savedNote = "Remove failed: \(error)"
        }
        refreshKeys()
        // The removed key is pastable again — offer it if nothing is selected.
        if entryKey.isEmpty { entryKey = CredentialCatalog.pickerChoices(present: presentKeys).first ?? "" }
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

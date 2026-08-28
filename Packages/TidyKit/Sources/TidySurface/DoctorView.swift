import SwiftUI
import TidyCore
import TidyStore

/// The `doctor` view: live permission status, on-disk paths, DB row counts, and the one-click
/// redacted diagnostic bundle. This is what makes a silently-dropped TCC grant *visible* (G7).
///
/// Every non-green row carries a collapsed "How to fix" with plain-language steps
/// (`DoctorTips` — pure and unit-tested; this view only renders its output).
public struct DoctorView: View {
    @ObservedObject var env: AppEnvironment
    @State private var permissions: [String: String] = [:]
    @State private var counts: [String: Int] = [:]
    @State private var lastErrors: [String: String] = [:]
    @State private var copied = false
    /// Which "How to fix" groups are open, keyed by row name — survives the 3s reload timer.
    @State private var expanded: Set<String> = []
    /// Wall-clock of the last completed manual sync, so the button can confirm it did something.
    @State private var syncedAt: String?
    /// Tracks the in-flight edge so completion is recorded exactly once.
    @State private var wasSyncing = false

    public init(env: AppEnvironment) { self.env = env }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Doctor").font(.title2).bold()

                section("Permissions") {
                    ForEach(permissions.keys.sorted(), id: \.self) { key in
                        let status = permissions[key] ?? "—"
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(key).font(.system(size: 12, design: .monospaced))
                                Spacer()
                                Text(status)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(color(for: status))
                            }
                            if let tip = DoctorTips.tip(forPermission: key, status: status) {
                                tipGroup(id: "perm:\(key)", tip: tip)
                            }
                        }
                    }
                    #if canImport(AppKit)
                    HStack {
                        Button("Request Accessibility") { PermissionInspector.requestAccessibility() }
                        Button("Request Notifications") { PermissionInspector.requestNotifications() }
                        Button("Open System Settings") { PermissionInspector.openSettings() }
                    }
                    .font(.caption)
                    #endif
                    Text("Screen Recording is never requested — window titles come from the Accessibility API (guardrail G3).")
                        .font(.caption).foregroundStyle(.secondary)
                }

                section("Ingest sources") {
                    ForEach(env.ingestReadiness, id: \.0.rawValue) { source, readiness in
                        let lastError = lastErrors[source.rawValue]
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(source.rawValue).font(.system(size: 12, design: .monospaced))
                                Spacer()
                                Text(DoctorTips.ingestLabel(readiness, lastError: lastError))
                                    .font(.system(size: 12))
                                    .multilineTextAlignment(.trailing)
                                    .foregroundStyle(ingestColor(readiness, lastError: lastError))
                            }
                            if let tip = DoctorTips.tip(for: source, readiness: readiness,
                                                        lastError: lastError,
                                                        configPath: env.paths.configURL.path) {
                                tipGroup(id: "ingest:\(source.rawValue)", tip: tip)
                            }
                        }
                    }
                    // A sync takes seconds to minutes. With no in-progress state the button looked
                    // dead on click — the rows do refresh on the 3s timer above, but not until the
                    // run finishes, so the first feedback arrived long after the click.
                    HStack(spacing: 8) {
                        Button(env.ingestInFlight ? "Syncing…" : "Sync now") {
                            syncedAt = nil
                            env.runIngestOnce()
                        }
                        .font(.caption)
                        .disabled(env.ingestInFlight)

                        if env.ingestInFlight {
                            ProgressView().controlSize(.small)
                        } else if let syncedAt {
                            Text("Finished \(syncedAt)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("A source with zero rows is idle for the reason shown — not silently broken.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                section("Paths") {
                    row("Database", env.paths.databaseURL.path)
                    row("Config", env.paths.configURL.path)
                    row("Logs", env.paths.currentLogURL.path)
                }

                section("Database") {
                    ForEach(counts.keys.sorted(), id: \.self) { t in
                        HStack {
                            Text(t).font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Text("\(counts[t] ?? 0)").font(.system(size: 12))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Button(copied ? "Copied ✓" : "Copy diagnostic bundle") {
                        env.copyDiagnostics(); copied = true
                    }
                    Text("Redacted: credentials appear by name only, and the whole bundle is scrubbed before it reaches the clipboard. Safe to paste into an AI assistant.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 520)
        .onAppear(perform: reload)
        // A permission granted in System Settings while this window is open must show up without
        // reopening it — a fresh grant looked "broken" to the first real user because this view
        // only reloaded onAppear.
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in reload() }
        .onChange(of: env.ingestInFlight) { _, running in
            if wasSyncing && !running {
                let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
                syncedAt = f.string(from: Date())
                reload()   // show the new counts immediately rather than up to 3s later
            }
            wasSyncing = running
        }
    }

    // MARK: helpers

    /// A collapsed, clearly-labeled fix-it panel. Expansion state keyed by a stable id so the
    /// reload timer doesn't slam groups shut while someone is reading.
    @ViewBuilder private func tipGroup(id: String, tip: TroubleshootingTip) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(id) },
            set: { open in if open { expanded.insert(id) } else { expanded.remove(id) } }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(tip.steps.enumerated()), id: \.offset) { i, step in
                    Text("\(i + 1). \(step)")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                #if canImport(AppKit)
                if let pane = tip.settingsPane {
                    Button("Open System Settings") { PermissionInspector.openSettings(pane: pane) }
                        .font(.caption)
                }
                if tip.offersGoogleSignIn {
                    googleSignInControls
                }
                #endif
            }
            .padding(.top, 2)
        } label: {
            Text("How to fix").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, 8)
    }

    /// Rendered inside the google needs-sign-in tip.
    @ViewBuilder private var googleSignInControls: some View {
        HStack(spacing: 8) {
            Button("Sign in with Google") { env.signInWithGoogle() }
                .font(.caption)
                .disabled(env.googleSignIn == .inProgress)
            switch env.googleSignIn {
            case .idle: EmptyView()
            case .inProgress: Text("Check your browser…").font(.caption).foregroundStyle(.secondary)
            case .succeeded: Text("Signed in ✓").font(.caption).foregroundStyle(.green)
            case .failed(let message): Text(message).font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func reload() {
        permissions = PermissionInspector().statuses()
        counts = (try? env.db.tableRowCounts()) ?? [:]
        var errors: [String: String] = [:]
        for source in IngestCoordinator.Source.allCases {
            if let error = ((try? env.db.syncState(source.rawValue)) ?? nil)?.lastError, !error.isEmpty {
                errors[source.rawValue] = error
            }
        }
        lastErrors = errors
    }

    private func color(for status: String) -> Color {
        switch StatusSeverity.classify(status) {
        case .healthy: return .green
        case .broken: return .red
        case .neutral: return .secondary
        case .attention: return .orange
        }
    }

    /// Ready sources render green — unless their last sync recorded an error, which is worth red.
    private func ingestColor(_ readiness: IngestCoordinator.Readiness, lastError: String?) -> Color {
        if readiness.canRun { return lastError == nil ? .green : .red }
        return .orange
    }

    @ViewBuilder private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
        }
    }
}

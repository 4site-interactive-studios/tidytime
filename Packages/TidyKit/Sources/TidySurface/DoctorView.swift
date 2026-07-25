import SwiftUI
import TidyCore
import TidyStore

/// The `doctor` view: live permission status, on-disk paths, DB row counts, and the one-click
/// redacted diagnostic bundle. This is what makes a silently-dropped TCC grant *visible* (G7).
public struct DoctorView: View {
    @ObservedObject var env: AppEnvironment
    @State private var permissions: [String: String] = [:]
    @State private var counts: [String: Int] = [:]
    @State private var copied = false

    public init(env: AppEnvironment) { self.env = env }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Doctor").font(.title2).bold()

                section("Permissions") {
                    ForEach(permissions.keys.sorted(), id: \.self) { key in
                        HStack {
                            Text(key).font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Text(permissions[key] ?? "—")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(color(for: permissions[key] ?? ""))
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
    }

    private func reload() {
        permissions = PermissionInspector().statuses()
        counts = (try? env.db.tableRowCounts()) ?? [:]
    }

    private func color(for status: String) -> Color {
        if status.hasPrefix("granted") { return .green }
        if status.hasPrefix("denied") { return .red }
        if status.contains("not requested") { return .secondary }
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

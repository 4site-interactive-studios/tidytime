import SwiftUI
import TidyCore
import TidyStore

/// The menu bar popover: today at a glance, plus the actions that matter most often.
public struct MenuBarPopover: View {
    @ObservedObject var env: AppEnvironment
    private let openWindow: (AppWindow) -> Void

    public init(env: AppEnvironment, openWindow: @escaping (AppWindow) -> Void) {
        self.env = env
        self.openWindow = openWindow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            todaySummary
            Divider()
            actions
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("TidyTime").font(.headline)
            Spacer()
            Text(statusLabel).font(.caption).foregroundStyle(statusColor)
        }
    }

    @ViewBuilder private var todaySummary: some View {
        if let today = env.today {
            VStack(alignment: .leading, spacing: 6) {
                Text(Format.hoursMinutes(today.observedSeconds) + " observed · "
                     + Format.minutes(today.loggedMinutes) + " logged")
                    .font(.system(size: 13, weight: .medium))
                ProgressView(value: min(1, today.attributionRate))
                Text("\(Int(today.attributionRate * 100))% attributed · \(today.suggestions.filter { $0.status == "pending" }.count) pending suggestions")
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(today.contextSwitches.switchCount) context switches · \(String(format: "%.1f", today.contextSwitches.switchesPerActiveHour))/hr")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("No data yet today.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(env.isCapturing ? "Pause capture" : "Resume capture") { env.toggleCapture() }
            Button("Open recap…") { openWindow(.recap) }
            Button("Dashboard…") { openWindow(.dashboard) }
            Button("Settings…") { openWindow(.settings) }
            Button("Doctor…") { openWindow(.doctor) }
            Divider()
            Button("Copy diagnostics") { env.copyDiagnostics() }
                .help("Copies a redacted bundle (env, config, permissions, row counts, recent logs) — safe to paste into an AI assistant.")
            Button("Quit TidyTime") { AppLifecycle.quit() }
        }
        .buttonStyle(.plain)
        .font(.system(size: 13))
    }

    private var statusLabel: String {
        switch env.status {
        case .idle: return "idle"
        case .capturing: return "capturing"
        case .paused: return "paused"
        case .attention(let m): return m
        }
    }
    private var statusColor: Color {
        switch env.status {
        case .capturing: return .green
        case .paused, .idle: return .secondary
        case .attention: return .orange
        }
    }
}

/// Windows the app can open from the menu bar.
public enum AppWindow: String, Identifiable, Sendable {
    case recap, dashboard, settings, doctor
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .recap: return "Recap"
        case .dashboard: return "Dashboard"
        case .settings: return "Settings"
        case .doctor: return "Doctor"
        }
    }
}

public enum AppLifecycle {
    public static func quit() {
        #if canImport(AppKit)
        NSApplication.shared.terminate(nil)
        #endif
    }
}

#if canImport(AppKit)
import AppKit
#endif

/// Small display helpers shared by the views.
public enum Format {
    public static func hoursMinutes(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
    public static func minutes(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
    public static func usd(_ v: Double) -> String { String(format: "$%.2f", v) }
    public static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

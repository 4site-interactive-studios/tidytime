import SwiftUI
import TidyCore

/// The two halves of "how was my day": today's cards, and the week around them.
///
/// They were separate windows, which made them feel like separate features. They are not — you look
/// at the recap to decide what to enter, and at the stats to see whether the week is going the way
/// you thought. Two windows meant two things to find, arrange and close, and no way to glance from
/// one to the other.
///
/// Renamed from "Dashboard" to "Stats": the old name described a *place in the app*, which is only
/// useful to someone who already knows the app. "Stats" describes what is on the screen.
public enum MainTab: String, CaseIterable, Identifiable, Sendable {
    case recap, stats
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .recap: return "Recap"
        case .stats: return "Stats"
        }
    }
    public var symbol: String {
        switch self {
        case .recap: return "list.bullet.rectangle"
        case .stats: return "chart.bar"
        }
    }

    /// The menu item the user clicked, mapped to the tab it should land on. Returns nil for windows
    /// that are not part of this one (Settings, Doctor).
    public init?(_ window: AppWindow) {
        switch window {
        case .recap: self = .recap
        case .stats: self = .stats
        default: return nil
        }
    }
}

/// Which tab the combined window is showing.
///
/// Held outside the view and owned by the app shell, because the tab has to be settable from the
/// menu bar: clicking "Stats…" while the window is already open must switch to Stats, not merely
/// front a window still showing the recap. A `@State` inside the view could not be reached from
/// there, and re-creating the window to change tabs would throw away the recap's selected day.
@available(macOS 14.0, *)
public final class MainWindowModel: ObservableObject {
    @Published public var tab: MainTab
    public init(tab: MainTab = .recap) { self.tab = tab }
}

@available(macOS 14.0, *)
public struct MainWindow: View {
    @ObservedObject var env: AppEnvironment
    @ObservedObject var model: MainWindowModel

    public init(env: AppEnvironment, model: MainWindowModel) {
        self.env = env
        self.model = model
    }

    public var body: some View {
        // `TabView` rather than a segmented control plus a switch: it keeps BOTH subtrees alive, so
        // stepping over to Stats and back does not reset the recap to today and re-run its query.
        // It also matches SettingsView, which is already tabbed, and gives keyboard navigation free.
        TabView(selection: $model.tab) {
            RecapWindow(env: env)
                .tabItem { Label(MainTab.recap.title, systemImage: MainTab.recap.symbol) }
                .tag(MainTab.recap)
            DashboardView(env: env)
                .tabItem { Label(MainTab.stats.title, systemImage: MainTab.stats.symbol) }
                .tag(MainTab.stats)
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}

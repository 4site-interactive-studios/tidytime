// TidyTime — app shell. Deliberately thin: it constructs `AppEnvironment` (which opens the DB,
// runs migrations, loads config, wires the Keychain + file logger and drives the pipeline) and
// hosts the SwiftUI surfaces from TidySurface. All logic lives in the TidyKit package so it stays
// unit-testable; this file is the part that can only be verified by running it.
//
// See docs/RUNNING.md and docs/architecture/module-map.md.
import SwiftUI
import AppKit
import Combine
import ServiceManagement
import TidyCore
import TidySurface

@main
struct TidyTimeApp: App {
    @StateObject private var launcher = AppLauncher()

    var body: some Scene {
        MenuBarExtra {
            switch launcher.state {
            case .starting:
                Text("Starting…").padding(12)
            case .failed(let message):
                StartupFailureView(message: message)
            case .ready(let env):
                MenuBarPopover(env: env) { window in
                    launcher.open(window, env: env)
                }
            }
        } label: {
            Image(systemName: launcher.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns startup (which can fail) and window presentation. `MenuBarExtra` has no `openWindow` for
/// auxiliary panels in a menu-bar-only app, so windows are managed with AppKit directly.
@MainActor
final class AppLauncher: ObservableObject {
    enum State {
        case starting
        case failed(String)
        case ready(AppEnvironment)
    }

    @Published private(set) var state: State = .starting
    // Keyed by AppWindow.windowKey, not by AppWindow: Recap and Stats are two tabs of ONE window
    // and must resolve to the same entry, or clicking the second menu item opens a duplicate.
    private var windows: [String: NSWindow] = [:]
    /// Which tab the combined window shows. Lives out here so the menu bar can set it on a window
    /// that is already open — re-creating the window instead would discard the recap's chosen day.
    private let mainModel = MainWindowModel()
    private var mainTabObservation: AnyCancellable?
    private var envObservation: AnyCancellable?
    private var recapObservation: AnyCancellable?

    init() {
        do {
            let env = try AppEnvironment()
            state = .ready(env)
            // The MenuBarExtra label observes THIS object, but the icon derives from env.status —
            // without forwarding, a pause or pipeline failure never updates the icon until
            // relaunch (round-3 finding R1-C3).
            envObservation = env.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            // The recap scheduler sets a flag rather than opening a window itself: AppEnvironment
            // lives in the package and has no access to SwiftUI's openWindow, which only exists in
            // the app shell. Observing the flag keeps that boundary intact.
            recapObservation = env.$shouldOpenRecap.sink { [weak self] due in
                guard due else { return }
                DispatchQueue.main.async {
                    self?.open(.recap, env: env)
                    env.acknowledgeRecapOpened()
                }
            }
            env.startCapture()
            registerLaunchAtLogin()
        } catch {
            state = .failed("\(error)")
        }
    }

    var menuBarSymbol: String {
        switch state {
        case .starting: return "clock"
        case .failed: return "exclamationmark.triangle"
        case .ready(let env):
            switch env.status {
            case .capturing: return "clock.badge.checkmark"
            case .paused, .idle: return "clock.badge.xmark"
            case .attention: return "exclamationmark.triangle"
            }
        }
    }

    /// Launch at login via SMAppService (no helper tool, no launchd plist — guardrail G8).
    private func registerLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } catch {
            // Non-fatal: the app still runs, it just won't auto-start.
            NSLog("TidyTime: launch-at-login registration failed: \(error)")
        }
    }

    func open(_ window: AppWindow, env: AppEnvironment) {
        // The menu item names a TAB, not just a window. Set it before fronting, so clicking
        // "Stats…" on an open window showing the recap actually lands on Stats.
        if let tab = MainTab(window) {
            if tab == .recap {
                try? env.refreshToday()
                // Explicitly asking for the recap means "show me today". The window is cached for
                // the life of the process, so without this the 17:00 scheduler on day two fronted a
                // window still showing day one. Paging with the chevrons still persists while the
                // window stays open — this only resets on an explicit open.
                mainModel.day = Date()
            }
            mainModel.tab = tab
        }
        if let existing = windows[window.windowKey] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root: AnyView
        switch window {
        case .recap, .stats: root = AnyView(MainWindow(env: env, model: mainModel))
        case .settings:      root = AnyView(SettingsView(env: env))
        case .doctor:        root = AnyView(DoctorView(env: env))
        }
        let hosting = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: hosting)
        win.title = "TidyTime — \(window.title)"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 900, height: 620))
        win.center()
        win.isReleasedWhenClosed = false
        windows[window.windowKey] = win
        // Follow the tab when the user switches it from inside the window, not just when the menu
        // opens it — otherwise the title bar says "Recap" while Stats is on screen.
        if MainTab(window) != nil {
            mainTabObservation = mainModel.$tab.sink { [weak win] tab in
                win?.title = "TidyTime — \(tab.title)"
            }
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Shown when the database or support directory can't be opened — better than a half-working app.
struct StartupFailureView: View {
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TidyTime couldn't start").font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Check that ~/Library/Application Support/TidyTime is writable, then relaunch.")
                .font(.caption)
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 340)
    }
}

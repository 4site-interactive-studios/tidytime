// TidyTimeApp — the thin app shell. Phase 0 fleshes this out: dependency container,
// DB open + migrations, config + Keychain plumbing, SMAppService launch-at-login, the
// permission prompts, and the `doctor` debug view. See docs/phases/phase-0-skeleton.md.
import SwiftUI
import AppKit

@main
struct TidyTimeApp: App {
    var body: some Scene {
        MenuBarExtra("TidyTime", systemImage: "clock.badge.checkmark") {
            // Placeholder popover. Phase 0 replaces with: today so far (observed vs. logged),
            // pending suggestion count, pause capture, open recap.
            Text("TidyTime")
                .font(.headline)
                .padding(.bottom, 4)
            Text("Skeleton build — see docs/phases/phase-0-skeleton.md")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Button("Quit TidyTime") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.window)
    }
}

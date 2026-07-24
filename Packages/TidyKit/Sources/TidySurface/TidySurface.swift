// TidySurface — reusable SwiftUI surfaces (menu bar popover, nudges, away prompt, recap,
// dashboard, settings) plus AppKit adapters that the app shell wires in. Presentation only:
// no capture, no network, no direct provider calls. See docs/architecture/module-map.md.
import Foundation
import AppKit
import TidyCore

/// AppKit-backed clipboard for the manual debug-mode "copy diagnostics" action.
/// (Tests use `FakeClipboard` from TidyCore; this concrete type talks to `NSPasteboard`.)
public struct SystemClipboard: ClipboardWriter {
    public init() {}
    public func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

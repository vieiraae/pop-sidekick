import AppKit
import SwiftUI

/// Hosts the settings window as a standard titled window (separate from the
/// floating popup panel).
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = NSHostingController(rootView: SettingsView())
        let win = NSWindow(contentViewController: controller)
        win.title = "Pop Sidekick Settings"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

import AppKit
import SwiftUI

enum SettingsTab: Hashable { case general, tasks, focusTrace, advanced }

/// Shared selection so external callers can open the
/// settings window on a specific tab.
@MainActor
final class SettingsSelection: ObservableObject {
    static let shared = SettingsSelection()
    @Published var tab: SettingsTab = .general
}

/// Hosts the settings window as a standard titled window (separate from the
/// floating popup panel).
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(tab: SettingsTab? = nil) {
        if let tab { SettingsSelection.shared.tab = tab }
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

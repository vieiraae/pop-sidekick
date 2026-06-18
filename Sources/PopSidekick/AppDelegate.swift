import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let selectionMonitor = SelectionMonitor()
    private let clipboardMonitor = ClipboardMonitor()
    private var popupController: PopupController?
    private var trustPollTimer: Timer?
    private var monitorStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Diag.log("launch: trusted=\(AccessibilityService.isTrusted)")

        popupController = PopupController()
        setupStatusItem()

        CopilotService.shared.start()
        clipboardMonitor.start()

        selectionMonitor.onSelection = { [weak self] selection, point in
            guard let self else { return }
            Diag.log("onSelection: len=\(selection.text.count) point=\(point) bounds=\(String(describing: selection.bounds))")
            guard !selection.text.isEmpty else { return }
            self.popupController?.show(text: selection.text, at: point, isEditable: selection.isEditable)
        }
        selectionMonitor.onSelectionCleared = { [weak self] in
            self?.popupController?.hideIfTransient()
        }
        selectionMonitor.isPointInPopup = { [weak self] point in
            self?.popupController?.popupContains(point) ?? false
        }

        if AccessibilityService.isTrusted {
            Diag.log("starting selection monitor (trusted)")
            startMonitorIfNeeded()
        } else {
            Diag.log("NOT trusted; prompting for accessibility")
            promptForAccessibility()
        }
        // Keep polling so the monitor starts the moment the user grants access,
        // without needing to relaunch the app.
        startTrustPolling()
    }

    private func startMonitorIfNeeded() {
        guard !monitorStarted else { return }
        monitorStarted = true
        selectionMonitor.start()
        Diag.log("selection monitor started")
    }

    private func startTrustPolling() {
        trustPollTimer?.invalidate()
        trustPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { return }
                if AccessibilityService.isTrusted {
                    self.startMonitorIfNeeded()
                    timer.invalidate()
                    self.trustPollTimer = nil
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        CopilotService.shared.stop()
        clipboardMonitor.stop()
        selectionMonitor.stop()
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Pop Sidekick")
            button.image?.isTemplate = true
            button.title = " Sidekick"
            button.imagePosition = .imageLeading
            Diag.log("status item created; button ok")
        } else {
            Diag.log("status item created; BUTTON IS NIL")
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Editor", action: #selector(openEditor), keyEquivalent: "e").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Pop Sidekick", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func openEditor() {
        popupController?.showFromMenuBar()
    }

    @objc private func openSettings() {
        SettingsWindow.show()
    }

    @objc private func promptForAccessibility() {
        let granted = AccessibilityService.requestPermission()
        if granted {
            startMonitorIfNeeded()
        } else {
            // Open the Accessibility settings pane to make granting easy.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            startTrustPolling()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

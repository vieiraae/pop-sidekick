import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let selectionMonitor = SelectionMonitor()
    private let clipboardMonitor = ClipboardMonitor()
    private var popupController: PopupController?
    private var trustPollTimer: Timer?
    private var monitorStarted = false
    private let hotkeyManager = HotkeyManager()
    private var settingsObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Diag.log("launch: trusted=\(AccessibilityService.isTrusted)")

        popupController = PopupController()
        setupStatusItem()

        CopilotService.shared.start()
        clipboardMonitor.start()
        LoginItem.sync(with: SettingsStore.shared.settings.launchAtLogin)

        selectionMonitor.onSelection = { [weak self] selection, point in
            guard let self else { return }
            Diag.log("onSelection: len=\(selection.text.count) point=\(point) bounds=\(String(describing: selection.bounds))")
            guard !selection.text.isEmpty else { return }
            self.popupController?.show(text: selection.text, at: point, isEditable: selection.isEditable, selectionBounds: selection.bounds)
        }
        selectionMonitor.onSelectionCleared = { [weak self] in
            self?.popupController?.hideIfTransient()
        }
        selectionMonitor.isPointInPopup = { [weak self] point in
            self?.popupController?.popupContains(point) ?? false
        }
        // Clear the selection dedupe when the popup hides, so selecting the same
        // text again re-shows it.
        popupController?.onHidden = { [weak self] in
            self?.selectionMonitor.reset()
        }
        popupController?.onEscapeDismiss = { [weak self] text in
            self?.selectionMonitor.suppressReshow(of: text)
        }

        // Global task hotkeys: run the task on the current selection.
        hotkeyManager.onTrigger = { [weak self] taskID in
            guard let self else { return }
            if taskID == HotkeyManager.clipboardHistoryActionID {
                self.popupController?.showClipboardHistory()
                return
            }
            guard let task = SettingsStore.shared.settings.tasks.first(where: { $0.id == taskID })
            else { return }
            self.popupController?.runTaskOnSelection(task)
        }
        hotkeyManager.register(tasks: SettingsStore.shared.settings.tasks,
                               clipboardHotkey: SettingsStore.shared.settings.clipboardHotkey)
        // Re-register whenever the task list / shortcuts change.
        settingsObservation = SettingsStore.shared.$settings
            .map { HotkeyRegistrationInput(tasks: $0.tasks, clipboardHotkey: $0.clipboardHotkey) }
            .removeDuplicates()
            .sink { [weak self] input in
                self?.hotkeyManager.register(tasks: input.tasks, clipboardHotkey: input.clipboardHotkey)
            }

        if AccessibilityService.isTrusted {
            Diag.log("starting selection monitor (trusted)")
            startMonitorIfNeeded()
        } else {
            Diag.log("NOT trusted; prompting for accessibility")
        }

        // First launch: show the onboarding guide; otherwise prompt for
        // Accessibility only if it hasn't been granted yet.
        if !SettingsStore.shared.settings.hasCompletedOnboarding {
            OnboardingWindow.show()
        } else if !AccessibilityService.isTrusted {
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
        menu.addItem(withTitle: "Setup Guide…", action: #selector(openOnboarding), keyEquivalent: "").target = self
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

    @objc private func openOnboarding() {
        OnboardingWindow.show()
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

/// Equatable bundle of the inputs that drive global hotkey registration, so the
/// settings observer only re-registers when the relevant fields change.
private struct HotkeyRegistrationInput: Equatable {
    var tasks: [TaskDef]
    var clipboardHotkey: Hotkey?
}

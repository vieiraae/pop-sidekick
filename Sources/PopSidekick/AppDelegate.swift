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
    private var focusTraceItem: NSMenuItem?
    private var focusTraceObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Clipboard history, images, settings (BYOK keys) and logs live here;
        // keep the whole folder private to this user.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PopSidekick", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
        Diag.log("launch: trusted=\(AccessibilityService.isTrusted)")

        // Accessory (menu-bar) apps don't get an automatic Dock icon, so macOS
        // has no icon to badge minimized windows with. Set it explicitly.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        installMainMenu()
        popupController = PopupController()
        setupStatusItem()
        focusTraceObservation = FocusTrace.shared.$isEnabled.sink { [weak self] on in
            self?.focusTraceItem?.state = on ? .on : .off
            self?.statusItem?.button?.image = NSImage(
                systemSymbolName: on ? "scribble.variable" : "sparkles",
                accessibilityDescription: "Pop Sidekick")
        }

        CopilotService.shared.start()
        clipboardMonitor.start()
        LoginItem.sync(with: SettingsStore.shared.settings.launchAtLogin)

        selectionMonitor.onSelection = { [weak self] selection, point in
            guard let self else { return }
            Diag.log("onSelection: len=\(selection.text.count) point=\(point) bounds=\(String(describing: selection.bounds))")
            guard !selection.text.isEmpty else { return }
            // Dragging while presenting selects text; don't pop up over the trace.
            guard !FocusTrace.shared.isEnabled else { return }
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
            if taskID == HotkeyManager.focusTraceActionID {
                self.toggleFocusTrace()
                return
            }
            guard let task = SettingsStore.shared.settings.tasks.first(where: { $0.id == taskID })
            else { return }
            self.popupController?.runTaskOnSelection(task)
        }
        hotkeyManager.register(tasks: SettingsStore.shared.settings.tasks,
                               clipboardHotkey: SettingsStore.shared.settings.clipboardHotkey,
                               focusTraceHotkey: SettingsStore.shared.settings.focusTraceHotkey)
        // Re-register whenever the task list / shortcuts change.
        settingsObservation = SettingsStore.shared.$settings
            .map { HotkeyRegistrationInput(tasks: $0.tasks, clipboardHotkey: $0.clipboardHotkey,
                                           focusTraceHotkey: $0.focusTraceHotkey) }
            .removeDuplicates()
            .sink { [weak self] input in
                self?.hotkeyManager.register(tasks: input.tasks, clipboardHotkey: input.clipboardHotkey,
                                             focusTraceHotkey: input.focusTraceHotkey)
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
        try? FileManager.default.removeItem(
            at: FileManager.default.temporaryDirectory.appendingPathComponent("PopSidekickPreview"))
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
        let trace = menu.addItem(withTitle: "FocusTrace", action: #selector(toggleFocusTraceFromMenu), keyEquivalent: "")
        trace.target = self
        trace.image = NSImage(systemSymbolName: "scribble.variable", accessibilityDescription: nil)
        focusTraceItem = trace
        menu.addItem(.separator())
        menu.addItem(withTitle: "Setup Guide…", action: #selector(openOnboarding), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Pop Sidekick", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleFocusTraceFromMenu() { toggleFocusTrace() }

    private func toggleFocusTrace() {
        FocusTrace.shared.toggle()
        if FocusTrace.shared.isEnabled { popupController?.hideIfTransient() }
    }

    @objc private func openEditor() {
        popupController?.showFromMenuBar()
    }

    /// Installs a minimal main menu so standard editing key equivalents
    /// (⌘X/⌘C/⌘V/⌘A/⌘Z) are routed to the focused text view. Accessory apps have
    /// no main menu by default, which otherwise breaks copy/paste in text fields.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu (first submenu). Provides Quit and standard app commands.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Hide Pop Sidekick", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Pop Sidekick", action: #selector(quit), keyEquivalent: "q").target = self

        // Edit menu with the standard responder-chain editing actions.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
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
    var focusTraceHotkey: Hotkey?
}

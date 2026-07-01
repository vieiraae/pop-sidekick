import AppKit

/// Watches for text selections across all applications and reports them.
///
/// Strategy:
/// 1. On a likely *selection gesture* (a mouse drag or a multi-click), read the
///    focused element's selected text via the Accessibility API.
/// 2. Chromium/Electron/WebKit apps are asked to expose their full AX tree on
///    demand (see `AccessibilityService.enableEnhancedAccessibility`), so their
///    selections are readable via AX too.
/// 3. Selection is read purely via Accessibility — the clipboard is never used,
///    so it stays untouched. Apps that expose no AX data simply get no popup.
@MainActor
final class SelectionMonitor {
    var onSelection: ((AccessibilityService.Selection, NSPoint) -> Void)?
    var onSelectionCleared: (() -> Void)?
    /// Returns true when a screen point is inside the visible popup, so clicks
    /// on our own popup (e.g. opening a menu) don't trigger selection probing.
    var isPointInPopup: ((NSPoint) -> Bool)?

    private var monitor: Any?
    private var lastText: String = ""
    /// Text the user explicitly dismissed (e.g. via Esc). While the same text is
    /// still selected, it must not re-trigger the popup; cleared as soon as a
    /// different selection appears or the selection is cleared.
    private var suppressedText: String?
    private var enabled = false

    private var mouseDownPoint: NSPoint = .zero

    /// How many times to re-probe the Accessibility API before giving up. The
    /// AX `kAXSelectedText` attribute often lags a frame or two behind the
    /// actual mouse/keyboard selection, so a single probe races and randomly
    /// misses real selections. Polling a few times closes that gap.
    private let maxPollAttempts = 5
    private let pollInterval: TimeInterval = 0.07

    /// Bumped on every `keyUp` so that a burst of typing coalesces into a single
    /// live probe chain. Each scheduled keyboard probe captures the token value
    /// at schedule time and bails the moment a newer keystroke supersedes it —
    /// otherwise rapid typing stacks many overlapping 5-attempt AX probe chains
    /// (each doing several synchronous cross-process AX queries) on the main
    /// thread, even though plain typing never produces a selection.
    private var keyProbeToken = 0

    func start() {
        guard monitor == nil else { return }
        enabled = true
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .keyUp]
        ) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        enabled = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    func setEnabled(_ value: Bool) { enabled = value }

    func reset() { lastText = "" }

    /// Suppresses re-showing the popup for `text` while it stays selected. Used
    /// after an explicit Esc dismissal so the Esc keyUp (or an unchanged
    /// selection) doesn't immediately reopen the popup.
    func suppressReshow(of text: String) {
        suppressedText = text
        lastText = text
    }

    private func handle(_ event: NSEvent) {
        guard enabled, SettingsStore.shared.settings.showPopupAutomatically else { return }

        switch event.type {
        case .leftMouseDown:
            if isPointInPopup?(NSEvent.mouseLocation) == true { return }
            mouseDownPoint = NSEvent.mouseLocation
            // Ask the frontmost app (esp. Chromium/Electron) to expose its full
            // accessibility tree now, so the selection is readable via AX by the
            // time the drag finishes — no clipboard fallback needed.
            if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                AccessibilityService.enableEnhancedAccessibility(for: pid)
            }
        case .leftMouseUp:
            let up = NSEvent.mouseLocation
            // Ignore interactions with our own popup (opening menus, buttons).
            if isPointInPopup?(up) == true { return }
            let dragDistance = hypot(up.x - mouseDownPoint.x, up.y - mouseDownPoint.y)
            let isGesture = dragDistance > 4 || event.clickCount >= 2
            guard isGesture else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.pollSelection(attempt: 0, fromMouse: true)
            }
        case .keyUp:
            // Ignore the keyUp from our own synthesized Cut/Copy/Paste, which
            // would otherwise re-probe the selection right after the action.
            if AccessibilityService.isSynthesizingKeystroke { return }
            keyProbeToken &+= 1
            let token = keyProbeToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.pollSelection(attempt: 0, fromMouse: false, keyToken: token)
            }
        default:
            break
        }
    }

    /// Probes the focused element for a selection, retrying a few times to ride
    /// out Accessibility API lag. Emits as soon as a real selection appears;
    /// only after all attempts come back empty does it clear. Selection is read
    /// purely via the Accessibility API — the clipboard is never touched.
    private func pollSelection(attempt: Int, fromMouse: Bool, keyToken: Int? = nil) {
        guard enabled else { return }
        // A newer keystroke has superseded this keyboard probe chain — abandon it
        // so overlapping chains don't pile up during fast typing.
        if let keyToken, keyToken != keyProbeToken { return }

        let probe = AccessibilityService.probeSelection()
        if case .selection(var selection) = probe {
            // AX bounds from web content (WebKit/Chromium) come back in an
            // inconsistent coordinate space and mislocate the popup. For
            // mouse-driven selections the cursor is already at the selection, so
            // drop the bounds and anchor at the mouse instead.
            if fromMouse { selection.bounds = nil }
            emit(selection, fromMouse: fromMouse)
            return
        }

        if attempt + 1 < maxPollAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
                self?.pollSelection(attempt: attempt + 1, fromMouse: fromMouse, keyToken: keyToken)
            }
            return
        }

        clearIfNeeded()
    }

    private func emit(_ selection: AccessibilityService.Selection, fromMouse: Bool) {
        if let suppressed = suppressedText {
            // The dismissed text is still selected — keep ignoring it. A genuinely
            // different selection lifts the suppression.
            if selection.text == suppressed { return }
            suppressedText = nil
        }
        guard selection.text != lastText else { return }
        lastText = selection.text
        let point = fromMouse ? NSEvent.mouseLocation : anchorPoint(for: selection)
        onSelection?(selection, point)
    }

    private func clearIfNeeded() {
        suppressedText = nil
        if !lastText.isEmpty {
            lastText = ""
            onSelectionCleared?()
        }
    }

    /// Bottom-left screen anchor (AppKit coordinates) for the popup.
    private func anchorPoint(for selection: AccessibilityService.Selection) -> NSPoint {
        if let bounds = selection.bounds {
            // AX bounds use a top-left origin relative to the primary display;
            // convert to AppKit's bottom-left global coordinates.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            return NSPoint(x: bounds.minX, y: primaryHeight - bounds.maxY)
        }
        return NSEvent.mouseLocation
    }
}

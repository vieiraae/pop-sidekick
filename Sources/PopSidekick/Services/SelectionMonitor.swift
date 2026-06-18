import AppKit

/// Watches for text selections across all applications and reports them.
///
/// Strategy:
/// 1. On a likely *selection gesture* (a mouse drag or a multi-click), read the
///    focused element's selected text via the Accessibility API.
/// 2. If AX exposes no selection (common for read-only text, web pages, PDFs),
///    fall back to a copy-based capture (synthesize Cmd+C, read, restore clipboard).
/// 3. Keyboard selections (Shift+Arrows) are handled via AX only.
@MainActor
final class SelectionMonitor {
    var onSelection: ((AccessibilityService.Selection, NSPoint) -> Void)?
    var onSelectionCleared: (() -> Void)?
    /// Returns true when a screen point is inside the visible popup, so clicks
    /// on our own popup (e.g. opening a menu) don't trigger selection probing.
    var isPointInPopup: ((NSPoint) -> Bool)?

    private var monitor: Any?
    private var lastText: String = ""
    private var enabled = false

    private var mouseDownPoint: NSPoint = .zero

    /// How many times to re-probe the Accessibility API before giving up. The
    /// AX `kAXSelectedText` attribute often lags a frame or two behind the
    /// actual mouse/keyboard selection, so a single probe races and randomly
    /// misses real selections. Polling a few times closes that gap.
    private let maxPollAttempts = 5
    private let pollInterval: TimeInterval = 0.07

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

    private func handle(_ event: NSEvent) {
        guard enabled, SettingsStore.shared.settings.showPopupAutomatically else { return }

        switch event.type {
        case .leftMouseDown:
            if isPointInPopup?(NSEvent.mouseLocation) == true { return }
            mouseDownPoint = NSEvent.mouseLocation
        case .leftMouseUp:
            let up = NSEvent.mouseLocation
            // Ignore interactions with our own popup (opening menus, buttons).
            if isPointInPopup?(up) == true { return }
            let dragDistance = hypot(up.x - mouseDownPoint.x, up.y - mouseDownPoint.y)
            let isGesture = dragDistance > 4 || event.clickCount >= 2
            guard isGesture else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.pollSelection(attempt: 0, allowCopyFallback: true)
            }
        case .keyUp:
            // Ignore the keyUp from our own synthesized ⌘C/⌘V/⌘X (e.g. the copy
            // fallback), which would otherwise re-probe and hide the popup.
            if AccessibilityService.isSynthesizingKeystroke { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.pollSelection(attempt: 0, allowCopyFallback: false)
            }
        default:
            break
        }
    }

    /// Probes the focused element for a selection, retrying a few times to ride
    /// out Accessibility API lag. Emits as soon as a real selection appears;
    /// only after all attempts come back empty does it clear or (for read-only
    /// contexts) try the copy-based fallback.
    private func pollSelection(attempt: Int, allowCopyFallback: Bool) {
        guard enabled else { return }

        let probe = AccessibilityService.probeSelection()
        if case .selection(let selection) = probe {
            emit(selection)
            return
        }

        if attempt + 1 < maxPollAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
                self?.pollSelection(attempt: attempt + 1, allowCopyFallback: allowCopyFallback)
            }
            return
        }

        // No AX selection after retries.
        switch probe {
        case .noSelectionInfo where allowCopyFallback:
            // Read-only / non-AX context (web page, PDF): fall back to copy.
            copyFallback()
        default:
            // `.emptyEditable` (focused text element with nothing selected) or a
            // keyboard event with no AX selection: do not copy-probe, since some
            // apps copy the whole current line on an empty ⌘C.
            clearIfNeeded()
        }
    }

    private func copyFallback() {
        AccessibilityService.captureSelectionViaCopy { [weak self] text in
            guard let self, self.enabled else { return }
            guard let text, !text.isEmpty else {
                self.clearIfNeeded()
                return
            }
            self.emit(AccessibilityService.Selection(text: text, bounds: nil, isEditable: true))
        }
    }

    private func emit(_ selection: AccessibilityService.Selection) {
        guard selection.text != lastText else { return }
        lastText = selection.text
        onSelection?(selection, anchorPoint(for: selection))
    }

    private func clearIfNeeded() {
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

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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.evaluate(allowCopyFallback: true)
            }
        case .keyUp:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.evaluate(allowCopyFallback: false)
            }
        default:
            break
        }
    }

    private func evaluate(allowCopyFallback: Bool) {
        guard enabled else { return }

        switch AccessibilityService.probeSelection() {
        case .selection(let selection):
            // 1. Accessibility selected text (precise, gives bounds when available).
            emit(selection)

        case .emptyEditable:
            // A text element is focused but nothing is selected. Do NOT run the
            // copy fallback here: apps like code editors copy the whole current
            // line on ⌘C with no selection, which would falsely show the popup.
            clearIfNeeded()

        case .noSelectionInfo:
            // 2. Copy-based fallback for read-only / non-AX contexts.
            guard allowCopyFallback else {
                clearIfNeeded()
                return
            }
            AccessibilityService.captureSelectionViaCopy { [weak self] text in
                guard let self, self.enabled else { return }
                guard let text, !text.isEmpty else {
                    self.clearIfNeeded()
                    return
                }
                self.emit(AccessibilityService.Selection(text: text, bounds: nil, isEditable: false))
            }
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

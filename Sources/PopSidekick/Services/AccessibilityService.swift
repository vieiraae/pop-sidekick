import AppKit
import ApplicationServices

/// Reads the current text selection via the Accessibility API and synthesizes
/// clipboard keystrokes (Cut/Copy/Paste) into the frontmost application.
enum AccessibilityService {

    /// Whether the app has been granted Accessibility (AX) permission.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user to grant Accessibility permission.
    @discardableResult
    static func requestPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    struct Selection {
        var text: String
        /// Selection bounds in screen coordinates (top-left origin), if known.
        var bounds: CGRect?
        /// Whether the source element accepts edits (so Cut/Paste/AI-replace
        /// make sense). Read-only contexts (web pages, PDFs) are not editable.
        var isEditable: Bool = true
    }

    /// Result of probing the focused UI element for a text selection.
    enum SelectionProbe {
        /// A non-empty selection was found via the Accessibility API.
        case selection(Selection)
        /// The focused element is a text element (it exposes a selected-text
        /// attribute) but nothing is currently selected. A copy-based fallback
        /// must NOT run here — some apps (e.g. code editors) copy the whole
        /// current line on ⌘C when there is no selection, which would produce a
        /// false positive popup.
        case emptyEditable
        /// The focused element exposes no selection info at all (common for
        /// read-only web pages and PDFs). A copy-based fallback may be tried.
        case noSelectionInfo
    }

    /// Probes the focused UI element to classify its selection state.
    static func probeSelection() -> SelectionProbe {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused
        else { return .noSelectionInfo }
        let axElement = element as! AXUIElement

        var textValue: CFTypeRef?
        let textStatus = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &textValue)

        if textStatus == .success,
           let text = textValue as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .selection(Selection(text: text,
                                        bounds: selectionBounds(for: axElement),
                                        isEditable: isEditable(axElement)))
        }

        // The element supports a selected-text attribute (so it's a text
        // element) but the selection is empty: there is genuinely no selection.
        if textStatus == .success {
            return .emptyEditable
        }

        // Some text elements expose a selected-text *range* even when the
        // selected-text string attribute is unavailable; an empty range here
        // still means there is no active selection.
        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success {
            return .emptyEditable
        }

        return .noSelectionInfo
    }

    /// Returns the currently selected text in the focused UI element, if any.
    static func currentSelection() -> Selection? {
        if case .selection(let selection) = probeSelection() { return selection }
        return nil
    }

    /// Whether the focused text element accepts edits to its selected text.
    private static func isEditable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        return false
    }

    /// Computes the screen rectangle covering the current selection range.
    private static func selectionBounds(for element: AXUIElement) -> CGRect? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeRef = rangeValue
        else { return nil }

        var boundsValue: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeRef,
            &boundsValue
        )
        guard result == .success, let boundsRef = boundsValue else { return nil }

        var rect = CGRect.zero
        if AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) {
            return rect.width.isFinite && rect.height.isFinite ? rect : nil
        }
        return nil
    }

    // MARK: - Clipboard keystrokes

    static func copy() { sendCommandKey(0x08) }   // C
    static func cut() { sendCommandKey(0x07) }     // X
    static func paste() { sendCommandKey(0x09) }   // V

    /// Places `text` on the pasteboard and pastes it into the frontmost app.
    static func pasteText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Give the frontmost app a moment to regain focus, then paste.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            paste()
        }
    }

    /// Synthesizes Command + the given key code down/up.
    private static func sendCommandKey(_ keyCode: CGKeyCode) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - Copy-based selection capture (works in read-only contexts)

    /// Captures the current selection by synthesizing ⌘C, reading the result,
    /// and then restoring the previous pasteboard contents. This works in apps
    /// that don't expose `kAXSelectedText` (web pages, PDFs, read-only views).
    static func captureSelectionViaCopy(completion: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let saved = snapshotPasteboard()
        // Write a unique sentinel so we can reliably tell whether ⌘C actually
        // replaced the pasteboard contents (changeCount alone can be unreliable).
        let sentinel = "__popsidekick_sentinel_\(UUID().uuidString)__"
        pb.clearContents()
        pb.setString(sentinel, forType: .string)
        copy()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            let current = pb.string(forType: .string)
            restorePasteboard(saved)
            guard let current, current != sentinel else {
                completion(nil)
                return
            }
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(trimmed.isEmpty ? nil : current)
        }
    }

    private static func snapshotPasteboard() -> [NSPasteboardItem] {
        let pb = NSPasteboard.general
        return pb.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        } ?? []
    }

    private static func restorePasteboard(_ items: [NSPasteboardItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if !items.isEmpty {
            pb.writeObjects(items)
        }
    }
}

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
        // Wake up the accessibility tree of Chromium/Electron/WebKit apps so they
        // expose `AXSelectedText` (and text-marker ranges) without us having to
        // synthesize ⌘C. By default those apps publish only a shallow AX tree;
        // setting `AXManualAccessibility`/`AXEnhancedUserInterface` on the app
        // element makes them build the full tree, exactly as VoiceOver does.
        if let app = NSWorkspace.shared.frontmostApplication {
            enableEnhancedAccessibility(for: app.processIdentifier)
        }

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

        // WebKit/Chromium web content often exposes the selection through a text
        // *marker* range rather than `AXSelectedText`. Resolve it to a string.
        if let markerText = selectedTextViaMarkerRange(for: axElement),
           !markerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .selection(Selection(text: markerText,
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

    /// Determines whether the focused element accepts edits, so the popup can
    /// offer write actions (Cut, Paste, replace-on-task) only where they apply.
    ///
    /// Now that the AX tree is awake (see `enableEnhancedAccessibility`), this is
    /// reliable across native, WebKit, and Chromium/Electron apps: the value
    /// attribute is settable on real text inputs (`<input>`, `<textarea>`,
    /// `contenteditable`, native fields) and not on static/read-only content.
    private static func isEditable(_ element: AXUIElement) -> Bool {
        // Primary signal: is the element's value writable?
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }

        // Secondary signal: the element's role denotes a text input.
        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
           let role = roleValue as? String {
            switch role {
            case kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField":
                return true
            default:
                break
            }
        }

        return false
    }

    // MARK: - Enhanced accessibility (Chromium / Electron / WebKit)

    /// Apps whose accessibility tree we've already requested, so we only set the
    /// attributes once per process.
    private static var enhancedAccessibilityPIDs: Set<pid_t> = []

    /// Private/undocumented AX attributes that ask Chromium- and AppKit-based
    /// apps to expose their full accessibility tree on demand.
    private static let kAXManualAccessibility = "AXManualAccessibility" as CFString
    private static let kAXEnhancedUserInterface = "AXEnhancedUserInterface" as CFString

    /// Requests that the given application expose its full accessibility tree.
    /// Chromium/Electron respond to `AXManualAccessibility`; some AppKit apps
    /// respond to `AXEnhancedUserInterface`. Both are best-effort and safe to
    /// set even on apps that ignore them.
    static func enableEnhancedAccessibility(for pid: pid_t) {
        guard !enhancedAccessibilityPIDs.contains(pid) else { return }
        enhancedAccessibilityPIDs.insert(pid)
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, kAXManualAccessibility, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, kAXEnhancedUserInterface, kCFBooleanTrue)
    }

    /// Resolves the selection of a WebKit/Chromium element via its text-marker
    /// range (`AXSelectedTextMarkerRange` → `AXStringForTextMarkerRange`).
    private static func selectedTextViaMarkerRange(for element: AXUIElement) -> String? {
        let selectedRangeAttr = "AXSelectedTextMarkerRange" as CFString
        let stringForRangeAttr = "AXStringForTextMarkerRange" as CFString

        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, selectedRangeAttr, &markerRange) == .success,
              let range = markerRange
        else { return nil }

        var stringValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, stringForRangeAttr, range, &stringValue) == .success
        else { return nil }
        return stringValue as? String
    }

    /// Returns the currently selected text in the focused UI element, if any.
    static func currentSelection() -> Selection? {
        if case .selection(let selection) = probeSelection() { return selection }
        return nil
    }

    /// Computes the screen rectangle covering the current selection range.
    /// Only the standard `AXSelectedTextRange` geometry is used here. Web content
    /// (WebKit/Chromium) reports geometry through text-marker ranges in an
    /// inconsistent coordinate space, so we deliberately return `nil` there and
    /// let the popup anchor at the mouse location instead.
    /// Computes the screen rectangle covering the current selection range, in AX
    /// (top-left origin) coordinates. Returns `nil` when no reliable geometry is
    /// available — including web content (WebKit/Chromium), whose `AXBoundsForRange`
    /// reports coordinates inconsistent with the element's own window. The popup
    /// then anchors at the mouse location instead of a bogus position.
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
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect),
              rect.width.isFinite, rect.height.isFinite, rect != .zero
        else { return nil }

        // Sanity-check against the element's own window (same AX coordinate
        // space). WebKit/Chromium report selection bounds that fall outside the
        // window, which would otherwise place the popup at the screen bottom.
        if let window = windowFrame(of: element), !window.insetBy(dx: -4, dy: -4).intersects(rect) {
            return nil
        }
        return rect
    }

    /// The frame of the window containing `element`, in AX (top-left) coordinates.
    private static func windowFrame(of element: AXUIElement) -> CGRect? {
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowValue) == .success,
              let windowRef = windowValue
        else { return nil }
        let window = windowRef as! AXUIElement

        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: - Clipboard keystrokes

    /// Timestamp of the most recently synthesized keystroke. The global
    /// selection monitor checks `isSynthesizingKeystroke` so it can ignore the
    /// `keyUp` events our own Cut/Copy/Paste actions generate — otherwise they
    /// would trigger an immediate re-probe of the selection.
    private(set) static var lastSyntheticKeyTime: Date = .distantPast
    static var isSynthesizingKeystroke: Bool {
        Date().timeIntervalSince(lastSyntheticKeyTime) < 0.3
    }

    static func copy() { sendCommandKey(0x08) }   // C
    static func cut() { sendCommandKey(0x07) }     // X
    static func paste() { sendCommandKey(0x09) }   // V
    /// Paste and Match Style (⌘⌥⇧V).
    static func pasteAndMatchStyle() {
        sendCommandKey(0x09, extraFlags: [.maskAlternate, .maskShift])
    }

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

    /// Synthesizes Command (+ optional extra modifiers) + the given key code.
    private static func sendCommandKey(_ keyCode: CGKeyCode, extraFlags: CGEventFlags = []) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let flags: CGEventFlags = [.maskCommand, extraFlags]
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        lastSyntheticKeyTime = Date()
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

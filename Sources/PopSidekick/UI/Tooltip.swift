import AppKit
import SwiftUI

/// A custom tooltip implementation.
///
/// SwiftUI's built-in `.help()` tooltips only fire for the active application's
/// key window. Pop Sidekick is an accessory app whose popup is a non-activating
/// panel, so it is never the "active app" and those tooltips never appear. This
/// re-implements tooltips with an `NSTrackingArea` using `.activeAlways`, shown
/// in a small borderless panel that floats above the popup.
@MainActor
final class TooltipController {
    static let shared = TooltipController()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var pending: DispatchWorkItem?

    func schedule(_ text: String, near rectInScreen: NSRect) {
        cancelPending()
        let work = DispatchWorkItem { [weak self] in self?.present(text, near: rectInScreen) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    func hide() {
        cancelPending()
        panel?.orderOut(nil)
    }

    private func present(_ text: String, near rect: NSRect) {
        let panel = panel ?? makePanel()
        self.panel = panel
        guard let label = label else { return }

        label.stringValue = text
        label.sizeToFit()
        let size = NSSize(width: ceil(label.frame.width) + 16,
                          height: ceil(label.frame.height) + 8)
        label.frame = NSRect(x: 8, y: 4, width: size.width - 16, height: size.height - 8)

        // Position centered just below the tracked control; flip above if it
        // would fall off the bottom of the screen.
        var x = rect.midX - size.width / 2
        var y = rect.minY - size.height - 5
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            if y < visible.minY { y = rect.maxY + 5 }
            x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)
        }
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 80, height: 24),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .transient]
        panel.hidesOnDeactivate = false

        let effect = NSVisualEffectView()
        effect.material = .toolTip
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 5
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 11)
        text.textColor = .labelColor
        text.backgroundColor = .clear
        text.isBordered = false
        text.isEditable = false
        effect.addSubview(text)
        label = text

        panel.contentView = effect
        return panel
    }
}

/// Installs an always-active hover tracker over the modified view that shows a
/// custom tooltip after a short delay.
private struct TooltipArea: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.text = text
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.text = text
    }

    final class TrackingView: NSView {
        var text: String = ""
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) {
            guard let window, !text.isEmpty else { return }
            let inWindow = convert(bounds, to: nil)
            let inScreen = window.convertToScreen(inWindow)
            TooltipController.shared.schedule(text, near: inScreen)
        }

        override func mouseExited(with event: NSEvent) {
            TooltipController.shared.hide()
        }
    }
}

extension View {
    /// A tooltip that works inside a non-activating accessory panel.
    func tooltip(_ text: String) -> some View {
        overlay(TooltipArea(text: text).allowsHitTesting(false))
    }

    /// Forces the standard arrow cursor while the pointer is over this view.
    /// Needed because the non-activating panel doesn't reset the source app's
    /// cursor (e.g. the I-beam left over from selecting text) on entry.
    func arrowCursor() -> some View {
        overlay(CursorArea().allowsHitTesting(false))
    }
}

/// Resets the cursor to the arrow whenever the pointer is over the modified
/// view, using an always-active tracking area (works even when the owning app
/// is not frontmost).
private struct CursorArea: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ nsView: CursorView, context: Context) {}

    final class CursorView: NSView {
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }
        override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }
        override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    }
}


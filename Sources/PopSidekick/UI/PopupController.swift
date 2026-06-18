import AppKit
import SwiftUI
import Combine

/// Owns the popup panel lifecycle: presentation, auto-sizing, positioning,
/// pinning, and outside-click / Escape dismissal.
@MainActor
final class PopupController: NSObject {
    static var shared: PopupController?

    private let panel = PopupPanel()
    private var hostingController: NSHostingController<PopupRootView>?
    private var viewModel: PopupViewModel?
    private var sizeObservation: NSKeyValueObservation?
    private var modeObservation: AnyCancellable?
    private var outsideMonitor: Any?
    private var escMonitor: Any?
    private var anchor: NSPoint = .zero

    override init() {
        super.init()
        PopupController.shared = self
    }

    var isVisible: Bool { panel.isVisible }

    /// Whether a screen point falls within the popup (used to ignore our own
    /// clicks in the global selection monitor). Generous vertical padding so an
    /// open menu hanging below the bar still counts as "inside".
    func popupContains(_ point: NSPoint) -> Bool {
        guard panel.isVisible else { return false }
        return panel.frame.insetBy(dx: -8, dy: -8).contains(point)
    }

    // MARK: - Presentation

    func show(text: String, at point: NSPoint, isEditable: Bool = true) {
        // If the same selection is already on screen, don't rebuild the popup.
        // Recreating the hosting controller swaps the content view and would
        // tear down an open menu/popover (making it flash and vanish).
        if panel.isVisible, let existing = viewModel,
           existing.selectedText == text, !existing.isProcessing {
            Diag.log("show: skipped rebuild (same selection already visible)")
            return
        }
        anchor = point
        let vm = PopupViewModel()
        vm.configure(with: text, isEditable: isEditable)
        vm.sourceApp = NSWorkspace.shared.frontmostApplication
        vm.onRequestClose = { [weak self] in self?.hide() }
        viewModel = vm

        let root = PopupRootView(vm: vm)
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = [.preferredContentSize]
        hostingController = controller
        panel.contentViewController = controller

        sizeObservation = controller.observe(\.preferredContentSize, options: [.new]) { [weak self] ctrl, _ in
            Task { @MainActor in self?.resizeAndReposition(to: ctrl.preferredContentSize) }
        }

        // When the popup expands/collapses, AppKit's automatic content sizing
        // resizes the window keeping its top-left fixed (growing downward, which
        // can run off the bottom of the screen). Re-clamp authoritatively once
        // the expand/collapse animation settles.
        modeObservation = vm.$mode
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                    guard let self, let ctrl = self.hostingController else { return }
                    self.resizeAndReposition(to: ctrl.preferredContentSize)
                }
            }

        resizeAndReposition(to: controller.preferredContentSize)
        panel.orderFrontRegardless()
        installDismissMonitors()
        Diag.log("show: size=\(controller.preferredContentSize) frame=\(panel.frame) visible=\(panel.isVisible)")
    }

    func showFromMenuBar() {
        // Manual invocation: read selection if available, else show an empty editor.
        if let selection = AccessibilityService.currentSelection() {
            let point = NSEvent.mouseLocation
            show(text: selection.text, at: point, isEditable: selection.isEditable)
            viewModel?.expandToEdit()
        } else {
            show(text: "", at: NSEvent.mouseLocation)
            viewModel?.expandToEdit()
        }
    }

    func hide() {
        Diag.log("hide")
        removeDismissMonitors()
        TooltipController.shared.hide()
        sizeObservation = nil
        modeObservation = nil
        panel.orderOut(nil)
        panel.contentViewController = nil
        hostingController = nil
        viewModel = nil
    }

    /// Hides the popup when the source selection is cleared (e.g. the user
    /// deleted or deselected the text), but only while it's a transient compact
    /// bar — never when pinned, expanded into the editor, or mid-run.
    func hideIfTransient() {
        guard let vm = viewModel else { return }
        guard vm.mode == .compact, !vm.pinned, !vm.isProcessing else { return }
        Diag.log("hideIfTransient")
        hide()
    }

    func setPinned(_ pinned: Bool) {
        panel.level = pinned ? .modalPanel : .floating
        if pinned { removeDismissMonitors() } else { installDismissMonitors() }
    }

    // MARK: - Layout

    private func resizeAndReposition(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else {
            var frame = panel.frame
            frame.size = size
            panel.setFrame(frame, display: true)
            return
        }
        let visible = screen.visibleFrame
        let gap: CGFloat = 6

        // Prefer placing the popup just below the selection anchor; flip above
        // if there isn't room below.
        var originX = anchor.x
        var originY = anchor.y - gap - size.height
        if originY < visible.minY + 4 {
            originY = anchor.y + gap
        }

        // Always clamp fully inside the visible frame so the (possibly tall,
        // expanded) window never spills off-screen and becomes unreachable.
        originX = min(max(originX, visible.minX + 4), max(visible.minX + 4, visible.maxX - size.width - 4))
        originY = min(max(originY, visible.minY + 4), max(visible.minY + 4, visible.maxY - size.height - 4))

        panel.setFrame(NSRect(x: originX, y: originY, width: size.width, height: size.height),
                       display: true, animate: false)
    }

    // MARK: - Dismissal

    private func installDismissMonitors() {
        removeDismissMonitors()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, let vm = self.viewModel, !vm.pinned else { return }
                let loc = NSEvent.mouseLocation
                if self.panel.frame.insetBy(dx: -4, dy: -4).contains(loc) {
                    Diag.log("outsideMonitor: ignored in-panel click at \(loc) frame=\(self.panel.frame)")
                    return
                }
                Diag.log("outsideMonitor: dismiss at \(loc) frame=\(self.panel.frame)")
                self.hide()
            }
        }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { // Escape
                Diag.log("escMonitor: forceClose")
                Task { @MainActor in self?.viewModel?.forceClose() }
                return nil
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
    }
}

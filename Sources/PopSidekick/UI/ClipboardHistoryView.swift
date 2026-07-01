import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A borderless floating panel that shows a clipboard image at (near) its
/// natural size, anchored beside the cursor. It never takes focus or mouse
/// events, so the hovered thumbnail keeps driving show/hide. Closes on Esc or
/// when the thumbnail reports the pointer left.
final class ImagePreviewController {
    static let shared = ImagePreviewController()

    private var panel: NSPanel?
    private var imageView: NSImageView?
    private var escMonitor: Any?

    func show(_ image: NSImage, near screenPoint: NSPoint) {
        let panel = ensurePanel()
        imageView?.image = image

        // Cap to 60% of the active screen while keeping aspect ratio.
        let screen = NSScreen.screens.first { NSMouseInRect(screenPoint, $0.frame, false) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let maxW = visible.width * 0.6
        let maxH = visible.height * 0.6
        var size = image.size
        if size.width <= 0 || size.height <= 0 { size = NSSize(width: 200, height: 200) }
        let scale = min(1, min(maxW / size.width, maxH / size.height))
        let target = NSSize(width: (size.width * scale).rounded(),
                            height: (size.height * scale).rounded())

        // Prefer to the right of the cursor; flip left / clamp to stay on-screen.
        let gap: CGFloat = 16
        var origin = NSPoint(x: screenPoint.x + gap, y: screenPoint.y - target.height / 2)
        if origin.x + target.width > visible.maxX {
            origin.x = screenPoint.x - gap - target.width
        }
        origin.x = max(visible.minX, min(origin.x, visible.maxX - target.width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - target.height))

        panel.setFrame(NSRect(origin: origin, size: target), display: true)
        panel.orderFrontRegardless()
        installEscMonitor()
    }

    func hide() {
        panel?.orderOut(nil)
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
    }

    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.hide() } // Esc
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.level = .popUpMenu
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 8
        iv.layer?.masksToBounds = true
        iv.layer?.borderWidth = 1
        iv.layer?.borderColor = NSColor.separatorColor.cgColor

        let container = NSView()
        container.wantsLayer = true
        container.addSubview(iv)
        iv.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            iv.topAnchor.constraint(equalTo: container.topAnchor),
            iv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        p.contentView = container

        panel = p
        imageView = iv
        return p
    }
}

extension NSImage {
    /// Returns a downscaled copy no taller than `maxHeight` (keeping aspect
    /// ratio). Used so clipboard-history thumbnails stay small and cheap; the
    /// original is returned unchanged when it's already small enough.
    func thumbnail(maxHeight: CGFloat) -> NSImage {
        let h = max(size.height, 1)
        guard h > maxHeight, size.width > 0 else { return self }
        let scale = maxHeight / h
        let newSize = NSSize(width: (size.width * scale).rounded(), height: maxHeight)
        let img = NSImage(size: newSize)
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: newSize),
             from: NSRect(origin: .zero, size: size),
             operation: .copy, fraction: 1.0)
        img.unlockFocus()
        return img
    }
}

/// A clipboard-history image thumbnail that stays compact (about two lines
/// tall). Hovering does NOT resize the row; instead it opens a floating preview
/// panel beside the cursor showing the image at its natural size. The panel
/// closes when the pointer leaves the thumbnail or the user presses Esc.
struct ClipImagePreview: View {
    let image: NSImage
    /// Roughly two lines of menu text.
    var compactHeight: CGFloat = 32

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: compactHeight)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.primary.opacity(0.12))
            )
            .onHover { inside in
                if inside {
                    ImagePreviewController.shared.show(image, near: NSEvent.mouseLocation)
                } else {
                    ImagePreviewController.shared.hide()
                }
            }
            .onDisappear { ImagePreviewController.shared.hide() }
    }
}

/// Standalone clipboard-history browser shown by the global hotkey. Lists the
/// recorded clips with the same per-item actions as the popup menu; pasting
/// targets the previously focused app.
struct ClipboardHistoryView: View {
    @ObservedObject var vm: PopupViewModel
    @ObservedObject var clipboard = ClipboardStore.shared

    private enum Tab: String, CaseIterable, Identifiable {
        case history, bookmarks
        var id: String { rawValue }
        var title: String { self == .history ? "History" : "Bookmarks" }
        var icon: String { self == .history ? "clock.arrow.circlepath" : "bookmark" }
    }

    private var tabBinding: Binding<Tab> {
        Binding(
            get: { vm.clipboardTab == .bookmarks ? .bookmarks : .history },
            set: { vm.clipboardTab = ($0 == .bookmarks) ? .bookmarks : .history }
        )
    }

    private var items: [ClipItem] {
        vm.clipboardTab == .bookmarks ? clipboard.bookmarks : clipboard.history
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Picker("", selection: tabBinding) {
                ForEach(Tab.allCases) { t in
                    Label(t.title, systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if items.isEmpty {
                Text(vm.clipboardTab == .bookmarks ? "No bookmarks yet." : "No clipboard history yet.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(items) { item in
                            ClipboardHistoryRow(vm: vm, item: item)
                            if item.id != items.last?.id {
                                Divider().opacity(0.4)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(12)
        .frame(width: Metrics.editWidth)
        .arrowCursor()
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.tint)
            Text("Sidekick Clipboard")
                .font(.headline)
            Spacer()
            if vm.clipboardTab == .history && !clipboard.history.isEmpty {
                IconButton(systemName: "trash", help: "Clear history") {
                    clipboard.clearHistory()
                }
            }
            IconButton(systemName: vm.pinned ? "pin.fill" : "pin",
                       help: vm.pinned ? "Unpin" : "Pin — keep window on top",
                       prominent: vm.pinned) {
                vm.pinned.toggle()
                PopupController.shared?.setPinned(vm.pinned)
            }
            IconButton(systemName: "xmark", help: "Close") { vm.forceClose() }
        }
    }
}

/// A single row in the standalone clipboard-history browser.
private struct ClipboardHistoryRow: View {
    @ObservedObject var vm: PopupViewModel
    @ObservedObject var clipboard = ClipboardStore.shared
    let item: ClipItem

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            preview
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .overlay(alignment: .trailing) {
            actions
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.primary.opacity(0.10)))
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                )
                .padding(.trailing, 4)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { primaryPaste() }
        .help("Double-click to paste")
    }

    /// Double-click action: paste into the source app, or copy when the source
    /// selection isn't editable. Rich-text clips are pasted as plain text.
    private func primaryPaste() {
        let style: PasteStyle = item.hasRichText ? .plainText : .source
        if vm.isEditable {
            vm.paste(item.content, style: style)
        } else {
            vm.copy(item.content, style: style)
        }
    }

    /// Writes the clip's image to a temporary PNG and opens it in Preview.app.
    private func openInPreview() {
        guard let image = item.content.image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekick-\(UUID().uuidString).png")
        guard (try? png.write(to: url)) != nil else { return }
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: config)
    }

    /// Presents a save panel and writes the clip's image as PNG to the chosen
    /// location.
    private func saveImageAs() {
        guard let image = item.content.image else { return }
        // The history window is a non-activating panel, so the app must be
        // brought forward for the save panel's name field to accept typing.
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "clipboard-image.png"
        panel.canCreateDirectories = true
        panel.title = "Save Image"
        panel.level = .modalPanel
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .image:
            if let image = item.content.image {
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ClipImagePreview(image: image)
                }
            } else {
                Label("Image", systemImage: "photo").font(.callout)
            }
        case .file:
            HStack(spacing: 6) {
                if let path = item.filePaths?.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "doc")
                }
                Text(item.preview).font(.callout).lineLimit(2)
            }
        case .link:
            Label(item.preview, systemImage: "link").font(.callout).lineLimit(2)
        case .richText:
            Label(item.preview, systemImage: "textformat").font(.callout).lineLimit(2)
        case .text:
            Label(item.preview, systemImage: "text.alignleft").font(.callout).lineLimit(2)
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if vm.isEditable {
                if item.isImage {
                    IconButton(systemName: "doc.on.clipboard", help: "Paste Extracted Text") {
                        vm.extractTextFromImage(item)
                    }
                }
                IconButton(systemName: "clipboard", help: "Paste") {
                    vm.paste(item.content, style: .source)
                }
            }
            IconButton(systemName: "doc.on.doc", help: "Copy") {
                vm.copy(item.content, style: .source)
            }
            if item.isImage {
                IconButton(systemName: "eye", help: "Open in Preview") {
                    openInPreview()
                }
                IconButton(systemName: "square.and.arrow.down", help: "Save Image As…") {
                    saveImageAs()
                }
            } else {
                IconButton(systemName: item.bookmarked ? "bookmark.fill" : "bookmark",
                           help: item.bookmarked ? "Remove bookmark" : "Bookmark") {
                    if item.bookmarked {
                        clipboard.unbookmark(item)
                    } else {
                        clipboard.bookmark(item)
                    }
                }
            }
            if item.isEditableText || item.isImage {
                IconButton(systemName: "sparkles", help: "Edit with Copilot") {
                    vm.editClipWithAI(item)
                }
            }
            IconButton(systemName: "trash", help: "Delete") { clipboard.delete(item) }
        }
    }
}

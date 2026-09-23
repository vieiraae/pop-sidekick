import AppKit
import SwiftUI

/// Borderless, non-activating panel for FocusTrace's interactive chrome, so
/// clicks work without stealing focus from the presented app.
final class FocusTracePanel: NSPanel {
    init(level: NSWindow.Level) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        self.level = level
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ExplainModel: ObservableObject {
    @Published var text = ""
    @Published var isRunning = false
    @Published var error: String?
    fileprivate var handle: RunHandle?

    func cancel() {
        if let handle { CopilotService.shared.cancel(handle) }
        handle = nil
        isRunning = false
    }
}

/// The X / copy / ✨ buttons shown next to a circled region, and the explanation card.
@MainActor
final class FocusTraceSelectionUI {
    /// Called when the user dismisses the selection (X or card close).
    var onDismiss: (() -> Void)?

    private let level: NSWindow.Level
    private var actions: FocusTracePanel?
    private var card: FocusTracePanel?
    private let model = ExplainModel()
    private var region: CGRect = .zero
    private var explainTask: Task<Void, Never>?

    init(level: NSWindow.Level) { self.level = level }

    var isVisible: Bool { actions != nil || card != nil }

    /// Shows the buttons at the top-right corner of `region` (global coords).
    func show(for region: CGRect) {
        hide()
        self.region = region
        let size = CGSize(width: 150, height: 52)
        let screen = Self.screen(for: region)
        var origin = CGPoint(x: region.maxX - size.width / 2, y: region.maxY - size.height / 2)
        origin = Self.clamp(origin, size: size, in: screen.visibleFrame)
        let panel = FocusTracePanel(level: level)
        panel.contentView = NSHostingView(rootView: SelectionActionsView(
            onClose: { [weak self] in self?.dismiss() },
            onCopy: { [weak self] done in self?.copyImage(done) },
            onExplain: { [weak self] in self?.explain() }
        ))
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        actions = panel
    }

    func hide() {
        explainTask?.cancel()
        explainTask = nil
        model.cancel()
        actions?.orderOut(nil)
        actions = nil
        card?.orderOut(nil)
        card = nil
    }

    private func dismiss() {
        hide()
        onDismiss?()
    }

    /// Copies the screen content inside the shape's bounds (the ink overlay and
    /// these buttons belong to Pop Sidekick, so the capture excludes them).
    private func copyImage(_ done: @escaping (Bool) -> Void) {
        guard ScreenCapture.hasPermission else {
            ScreenCapture.requestPermission()
            model.cancel()
            model.text = ""
            model.isRunning = false
            model.error = "Pop Sidekick needs Screen Recording permission to copy the circled area. Grant it in System Settings, then try again."
            showCard()
            done(false)
            return
        }
        let region = self.region
        Task { @MainActor in
            do {
                let png = try await ScreenCapture.capturePNG(region: region)
                let pb = NSPasteboard.general
                pb.clearContents()
                if let image = NSImage(data: png) {
                    pb.writeObjects([image])
                }
                pb.setData(png, forType: .png)
                done(true)
            } catch {
                NSSound.beep()
                done(false)
            }
        }
    }

    private func explain() {
        model.cancel()
        model.text = ""
        model.error = nil
        model.isRunning = true
        showCard()

        let region = self.region.insetBy(dx: -6, dy: -6)
        explainTask = Task { [weak self] in
            guard let self else { return }
            if !ScreenCapture.hasPermission {
                ScreenCapture.requestPermission()
                self.model.isRunning = false
                self.model.error = "Pop Sidekick needs Screen Recording permission to see the circled area. Grant it in System Settings, then try again."
                return
            }
            do {
                let png = try await ScreenCapture.capturePNG(region: region)
                guard !Task.isCancelled else { return }
                self.run(png: png)
            } catch {
                self.model.isRunning = false
                self.model.error = error.localizedDescription
            }
        }
    }

    private func run(png: Data) {
        let attachment: [String: Any] = [
            "type": "blob",
            "data": png.base64EncodedString(),
            "mimeType": "image/png",
            "displayName": "focustrace-selection.png",
        ]
        let prompt = """
        The attached image is a region of the screen that a presenter circled to \
        draw the audience's attention. Explain what it shows and why it matters, \
        clearly and concisely: a one-sentence summary, then up to four short \
        bullet points starting with "• ". Plain text only, no headings.
        """
        let copilot = CopilotService.shared
        let handle = copilot.run(prompt: prompt, model: SettingsStore.shared.settings.model,
                                 choices: 1, attachments: [attachment])
        model.handle = handle
        handle.onDelta = { [weak self] _, piece in self?.model.text += piece }
        handle.onResult = { [weak self] _, text in if !text.isEmpty { self?.model.text = text } }
        handle.onError = { [weak self] message in
            self?.model.error = message
            self?.model.isRunning = false
            self?.model.handle = nil
        }
        handle.onDone = { [weak self] in
            self?.model.isRunning = false
            self?.model.handle = nil
        }
    }

    private func showCard() {
        let size = CGSize(width: 380, height: 300)
        let screen = Self.screen(for: region).visibleFrame
        // Prefer the right of the region, then the left, aligned to its top.
        var x = region.maxX + 16
        if x + size.width > screen.maxX { x = region.minX - 16 - size.width }
        let origin = Self.clamp(CGPoint(x: x, y: region.maxY - size.height), size: size, in: screen)
        let panel = card ?? FocusTracePanel(level: level)
        if card == nil {
            panel.contentView = NSHostingView(rootView: ExplainCardView(
                model: model,
                onClose: { [weak self] in self?.dismiss() }
            ))
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        card = panel
    }

    private static func screen(for rect: CGRect) -> NSScreen {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(c) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private static func clamp(_ p: CGPoint, size: CGSize, in frame: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, frame.minX + 8), frame.maxX - size.width - 8),
                y: min(max(p.y, frame.minY + 8), frame.maxY - size.height - 8))
    }
}

// MARK: - Views

private struct SelectionActionsView: View {
    let onClose: () -> Void
    let onCopy: (@escaping (Bool) -> Void) -> Void
    let onExplain: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            GlassCircleButton(systemName: "xmark", help: "Close", action: onClose)
            GlassCircleButton(systemName: copied ? "checkmark" : "doc.on.doc",
                              help: "Copy image to clipboard", tint: copied ? .green : .white) {
                onCopy { ok in
                    guard ok else { return }
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        withAnimation { copied = false }
                    }
                }
            }
            GlassCircleButton(systemName: "sparkles", help: "Explain with Copilot", tint: .white, action: onExplain)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GlassCircleButton: View {
    let systemName: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(GlassBackground(shape: Circle()))
        .scaleEffect(hovering ? 1.08 : 1)
        .animation(.spring(duration: 0.25), value: hovering)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Liquid glass on macOS 26+, frosted material before that.
struct GlassBackground<S: Shape>: ViewModifier {
    let shape: S
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.25), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        }
    }
}

private struct ExplainCardView: View {
    @ObservedObject var model: ExplainModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AnimatedIcon(systemName: "sparkles", active: model.isRunning)
                    .font(.system(size: 14, weight: .semibold))
                Text("Explain").font(.headline)
                Spacer()
                if !model.text.isEmpty && !model.isRunning {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy")
                }
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless).help("Close")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if model.text.isEmpty {
                        Text(model.isRunning ? "Looking at the selection…" : "No explanation returned.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(Self.markdown(model.text))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 13))
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(GlassBackground(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)))
        .padding(4)
    }

    private static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

import SwiftUI
import AppKit

/// Hosts the first-run onboarding as a standard titled window.
@MainActor
enum OnboardingWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = NSHostingController(rootView: OnboardingView { close() })
        let win = NSWindow(contentViewController: controller)
        win.title = "Welcome to Pop Sidekick"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() {
        window?.close()
        window = nil
    }
}

/// A short, stepped first-run guide: welcome, Accessibility permission, and a
/// Copilot CLI check, finishing by marking onboarding complete.
struct OnboardingView: View {
    @ObservedObject private var store = SettingsStore.shared
    var onFinish: () -> Void

    @State private var step = 0
    @State private var accessibilityTrusted = AccessibilityService.isTrusted
    @State private var copilotValid = false
    @State private var nodeFound = false

    private let lastStep = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)

            Divider()

            HStack {
                ForEach(0...lastStep, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }
                }
                if step < lastStep {
                    Button("Continue") { step += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Get Started") { finish() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 460, height: 360)
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            accessibilityTrusted = AccessibilityService.isTrusted
            refreshChecks()
        }
        .onAppear { refreshChecks() }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcome
        case 1: accessibility
        default: copilot
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                Text("Pop Sidekick")
                    .font(.largeTitle.weight(.semibold))
            }
            Text("Select text in any app and a compact toolbar pops up next to it — cut, copy, paste, clipboard history, bookmarks, and AI tasks powered by GitHub Copilot.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            featureRow("cursorarrow.rays", "Works everywhere", "A floating toolbar appears wherever you select text.")
            featureRow("wand.and.stars", "AI tasks", "Proofread, rewrite, summarize, translate, and your own custom tasks.")
            featureRow("clock.arrow.circlepath", "Clipboard history & bookmarks", "Keep and reuse what you copy, including rich text and images.")
        }
    }

    private var accessibility: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("lock.shield", "Grant Accessibility access")
            Text("Pop Sidekick needs Accessibility permission to detect selected text and paste results across apps. Your text never leaves your Mac except when you run an AI task.")
                .font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Image(systemName: accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(accessibilityTrusted ? .green : .orange)
                Text(accessibilityTrusted ? "Accessibility granted." : "Accessibility not granted yet.")
                Spacer()
                if !accessibilityTrusted {
                    Button("Grant…") { grantAccessibility() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        }
    }

    private var copilot: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("terminal", "Connect GitHub Copilot")
            Text("AI tasks run through your installed Copilot CLI. Point Pop Sidekick at it and make sure Node.js is available.")
                .font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Copilot CLI path", text: $store.settings.copilotPath)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") { pickCopilot() }
            }
            checkRow(copilotValid, ok: "Copilot CLI found.", bad: "Copilot CLI not found at this path.")
            checkRow(nodeFound, ok: "Node.js runtime found.", bad: "Node.js not found — install with `brew install node`.")
        }
    }

    // MARK: - Pieces

    private func stepHeader(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(.tint)
            Text(title).font(.title2.weight(.semibold))
        }
    }

    private func featureRow(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func checkRow(_ ok: Bool, ok okText: String, bad badText: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(ok ? okText : badText)
                .font(.callout)
                .foregroundStyle(ok ? .primary : .secondary)
        }
    }

    // MARK: - Actions

    private func refreshChecks() {
        let path = SettingsStore.expand(store.settings.copilotPath)
        copilotValid = FileManager.default.isExecutableFile(atPath: path)
        nodeFound = CopilotService.nodeExecutablePath() != nil
    }

    private func grantAccessibility() {
        if !AccessibilityService.requestPermission() {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func pickCopilot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            store.settings.copilotPath = url.path
            refreshChecks()
        }
    }

    private func finish() {
        store.settings.hasCompletedOnboarding = true
        onFinish()
    }
}

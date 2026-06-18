import AppKit

/// Polls the general pasteboard for changes and records new text into history.
@MainActor
final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount

    func start() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        if let text = pb.string(forType: .string) {
            ClipboardStore.shared.record(text)
        }
    }
}

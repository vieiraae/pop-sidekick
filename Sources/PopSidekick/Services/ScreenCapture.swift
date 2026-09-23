import AppKit
import ScreenCaptureKit
import CoreMedia

/// ScreenCaptureKit helpers for FocusTrace. Our own windows are always
/// excluded, so the magnifier and "explain" snapshots never see the overlay.
enum ScreenCapture {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    static func filter(for displayID: CGDirectDisplayID) async throws -> (SCContentFilter, SCDisplay) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "PopSidekick", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Display not available for capture."])
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let me = content.applications.filter { $0.processID == pid }
        return (SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []), display)
    }

    /// Captures a region given in global Cocoa screen coordinates as PNG data.
    static func capturePNG(region: CGRect) async throws -> Data {
        let center = CGPoint(x: region.midX, y: region.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main,
              let id = displayID(of: screen) else {
            throw NSError(domain: "PopSidekick", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "No screen for the selected region."])
        }
        let rect = region.intersection(screen.frame)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else {
            throw NSError(domain: "PopSidekick", code: 13,
                          userInfo: [NSLocalizedDescriptionKey: "The selected region is empty."])
        }
        let (filter, _) = try await filter(for: id)
        let config = SCStreamConfiguration()
        // sourceRect is in display points with a top-left origin.
        config.sourceRect = CGRect(x: rect.minX - screen.frame.minX,
                                   y: screen.frame.maxY - rect.maxY,
                                   width: rect.width, height: rect.height)
        let scale = screen.backingScaleFactor
        config.width = max(1, Int(rect.width * scale))
        config.height = max(1, Int(rect.height * scale))
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "PopSidekick", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't encode the snapshot."])
        }
        return png
    }
}

/// Live, full-resolution mirror of one display, delivered as IOSurfaces that
/// the magnifier lens crops on the GPU via `contentsRect`.
final class ScreenMirror: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private(set) var displayID: CGDirectDisplayID?
    private let queue = DispatchQueue(label: "PopSidekick.ScreenMirror")
    /// Called on the main thread with each complete frame.
    var onFrame: ((IOSurface) -> Void)?
    private var generation = 0

    func start(displayID: CGDirectDisplayID) {
        guard displayID != self.displayID || stream == nil else { return }
        stop()
        self.displayID = displayID
        generation += 1
        let gen = generation
        Task { [weak self] in
            guard let self else { return }
            do {
                let (filter, display) = try await ScreenCapture.filter(for: displayID)
                let config = SCStreamConfiguration()
                let scale = CGFloat(filter.pointPixelScale)
                config.width = Int(CGFloat(display.width) * scale)
                config.height = Int(CGFloat(display.height) * scale)
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = false
                config.queueDepth = 4
                let s = SCStream(filter: filter, configuration: config, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try await s.startCapture()
                await MainActor.run {
                    if gen == self.generation { self.stream = s } else { Task { try? await s.stopCapture() } }
                }
            } catch {
                Diag.log("ScreenMirror start failed: \(error.localizedDescription)")
                await MainActor.run { if gen == self.generation { self.displayID = nil } }
            }
        }
    }

    func stop() {
        generation += 1
        displayID = nil
        if let s = stream {
            stream = nil
            Task { try? await s.stopCapture() }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let infos = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = infos.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }
        let s = surface as IOSurface
        DispatchQueue.main.async { [weak self] in self?.onFrame?(s) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.displayID = nil
        }
    }
}

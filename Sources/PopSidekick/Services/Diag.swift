import Foundation

/// Lightweight file logger for diagnosing runtime behaviour (the app is an
/// accessory with no console). Disabled by default; enable by launching with
/// the `POPSIDEKICK_DEBUG=1` environment variable so production builds don't
/// persist selection metadata to disk. Writes to
/// Application Support/PopSidekick/diag.log and is capped to avoid unbounded
/// growth.
enum Diag {
    /// Whether diagnostic logging is active. Off unless explicitly enabled.
    static let isEnabled: Bool = {
        ProcessInfo.processInfo.environment["POPSIDEKICK_DEBUG"] == "1"
    }()

    /// Cap the log file at ~512 KB; it's truncated when it grows past this.
    private static let maxBytes: UInt64 = 512 * 1024

    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PopSidekick", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diag.log")
    }()

    static func log(_ message: String) {
        guard isEnabled else { return }
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            if ((try? handle.seekToEnd()) ?? 0) > maxBytes {
                try? handle.truncate(atOffset: 0)
            }
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }
}

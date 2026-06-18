import Foundation
import Combine

struct ModelOption: Identifiable, Hashable {
    var id: String
    var name: String
}

/// One result stream produced by a `run` request (possibly multiple choices).
final class RunHandle {
    let id: String
    var onDelta: (Int, String) -> Void = { _, _ in }
    var onResult: (Int, String) -> Void = { _, _ in }
    var onError: (String) -> Void = { _ in }
    var onDone: () -> Void = {}
    init(id: String) { self.id = id }
}

/// Manages the long-lived Node bridge process that talks to the Copilot SDK.
@MainActor
final class CopilotService: ObservableObject {
    static let shared = CopilotService()

    @Published var models: [ModelOption] = [ModelOption(id: "auto", name: "Auto")]
    @Published var bridgeReady = false
    @Published var lastError: String?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutBuffer = Data()
    private var handles: [String: RunHandle] = [:]
    private var modelsCompletion: ((Result<[ModelOption], Error>) -> Void)?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard process == nil else { return }
        guard let node = Self.locateNode() else {
            lastError = "Could not find a Node.js executable. Install Node 20+ (e.g. `brew install node`)."
            return
        }
        guard let bridgeDir = Self.locateBridgeDir() else {
            lastError = "Could not locate the Copilot bridge resources."
            return
        }
        let bridge = bridgeDir.appendingPathComponent("copilot-bridge.mjs")

        let proc = Process()
        proc.executableURL = node
        proc.arguments = [bridge.path]
        proc.currentDirectoryURL = bridgeDir

        var env = ProcessInfo.processInfo.environment
        env["POPSIDEKICK_COPILOT_PATH"] = SettingsStore.shared.settings.copilotPath
        // Ensure node and copilot can be found on PATH.
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let existing = env["PATH"] ?? ""
        env["PATH"] = (extraPaths + [existing]).joined(separator: ":")
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.ingest(data) }
        }

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.handleTermination() }
        }

        do {
            try proc.run()
        } catch {
            lastError = "Failed to launch bridge: \(error.localizedDescription)"
            return
        }

        self.process = proc
        self.stdinPipe = inPipe
    }

    func stop() {
        send(["cmd": "shutdown"])
        process?.terminate()
        process = nil
        stdinPipe = nil
        bridgeReady = false
    }

    private func handleTermination() {
        bridgeReady = false
        process = nil
        stdinPipe = nil
        for handle in handles.values { handle.onError("Bridge process exited.") }
        handles.removeAll()
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.start()
        }
    }

    // MARK: - Requests

    func refreshModels(completion: ((Result<[ModelOption], Error>) -> Void)? = nil) {
        ensureStarted()
        modelsCompletion = completion
        send(["cmd": "listModels", "id": "models"])
    }

    @discardableResult
    func run(prompt: String, model: String, choices: Int) -> RunHandle {
        ensureStarted()
        let settings = SettingsStore.shared.settings
        let id = UUID().uuidString
        let handle = RunHandle(id: id)
        handles[id] = handle

        var payload: [String: Any] = [
            "cmd": "run",
            "id": id,
            "prompt": prompt,
            "model": model,
            "choices": choices,
            "systemMessage": settings.systemMessage,
        ]
        if settings.useSkillsFolder, !settings.skillsFolderPath.isEmpty {
            payload["skillDirectories"] = [SettingsStore.expand(settings.skillsFolderPath)]
            payload["enableConfigDiscovery"] = true
        }
        if settings.useMCP {
            if let servers = Self.loadMCPServers(settings: settings) {
                payload["mcpServers"] = servers
            }
        }
        send(payload)
        return handle
    }

    func cancel(_ handle: RunHandle) {
        send(["cmd": "cancel", "id": handle.id])
        handles[handle.id] = nil
    }

    private func ensureStarted() {
        if process == nil { start() }
    }

    // MARK: - I/O

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let pipe = stdinPipe else { return }
        var line = data
        line.append(0x0A)
        pipe.fileHandleForWriting.write(line)
    }

    private func ingest(_ data: Data) {
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            handleEvent(obj)
        }
    }

    private func handleEvent(_ event: [String: Any]) {
        let type = event["type"] as? String ?? ""
        switch type {
        case "ready":
            bridgeReady = true
            refreshModels()
        case "models":
            let arr = event["models"] as? [[String: Any]] ?? []
            var opts = arr.compactMap { dict -> ModelOption? in
                guard let id = dict["id"] as? String else { return nil }
                return ModelOption(id: id, name: dict["name"] as? String ?? id)
            }
            if !opts.contains(where: { $0.id == "auto" }) {
                opts.insert(ModelOption(id: "auto", name: "Auto"), at: 0)
            }
            models = opts
            modelsCompletion?(.success(opts))
            modelsCompletion = nil
        case "delta":
            if let id = event["id"] as? String, let h = handles[id] {
                h.onDelta(event["choice"] as? Int ?? 0, event["text"] as? String ?? "")
            }
        case "result":
            if let id = event["id"] as? String, let h = handles[id] {
                h.onResult(event["choice"] as? Int ?? 0, event["text"] as? String ?? "")
            }
        case "done":
            if let id = event["id"] as? String, let h = handles[id] {
                h.onDone()
                handles[id] = nil
            }
        case "error":
            let message = event["message"] as? String ?? "Unknown error"
            if let id = event["id"] as? String, let h = handles[id] {
                h.onError(message)
                handles[id] = nil
            } else {
                lastError = message
                modelsCompletion?(.failure(NSError(domain: "PopSidekick", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message])))
                modelsCompletion = nil
            }
        default:
            break
        }
    }

    // MARK: - Discovery helpers

    private static func locateNode() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Fall back to `which node` via login shell.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v node"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
           FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func locateBridgeDir() -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["POPSIDEKICK_BRIDGE_DIR"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("bridge"))
        }
        let exeDir = Bundle.main.executableURL?.deletingLastPathComponent()
        if let exeDir {
            candidates.append(exeDir.appendingPathComponent("bridge"))
            candidates.append(exeDir.appendingPathComponent("../Resources/bridge"))
        }
        // Dev fallback: repo bridge relative to this source file.
        let devBridge = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // PopSidekick
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("bridge")
        candidates.append(devBridge)

        for dir in candidates {
            let entry = dir.appendingPathComponent("copilot-bridge.mjs")
            if FileManager.default.fileExists(atPath: entry.path) {
                return dir.standardizedFileURL
            }
        }
        return nil
    }

    /// Loads enabled MCP servers from the configured mcp.json file.
    private static func loadMCPServers(settings: AppSettings) -> [String: Any]? {
        let path = SettingsStore.expand(settings.mcpConfigPath)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // Support both { "mcpServers": {...} } and a bare object of servers.
        let servers = (json["mcpServers"] as? [String: Any]) ?? json
        let disabled = Set(settings.mcpServerToggles.filter { !$0.enabled }.map { $0.name })
        let filtered = servers.filter { !disabled.contains($0.key) }
        return filtered.isEmpty ? nil : filtered
    }
}

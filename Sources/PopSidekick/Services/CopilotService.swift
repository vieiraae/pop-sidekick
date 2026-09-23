import Foundation
import Combine

struct ModelOption: Identifiable, Hashable {
    var id: String
    var name: String
    /// Reasoning efforts the model accepts (empty = not configurable).
    var efforts: [String] = []
    var defaultEffort: String?
}

/// Reasoning effort levels accepted by the Copilot SDK, lowest to highest.
enum ReasoningLevel {
    static let all = ["low", "medium", "high", "xhigh", "max"]
    static func label(_ e: String) -> String {
        switch e {
        case "": return "Model default"
        case "xhigh": return "Extra high"
        default: return e.capitalized
        }
    }
    static func icon(_ e: String) -> String {
        switch e {
        case "low": return "gauge.with.dots.needle.0percent"
        case "medium": return "gauge.with.dots.needle.33percent"
        case "high": return "gauge.with.dots.needle.50percent"
        case "xhigh": return "gauge.with.dots.needle.67percent"
        case "max": return "gauge.with.dots.needle.100percent"
        default: return "gauge.with.dots.needle.bottom.50percent"
        }
    }
    /// The requested effort if the model supports it, otherwise the closest
    /// supported level; nil when the model has no configurable effort.
    static func resolve(_ requested: String, supported: [String]) -> String? {
        guard !requested.isEmpty, !supported.isEmpty else { return nil }
        if supported.contains(requested) { return requested }
        let r = all.firstIndex(of: requested) ?? 0
        return supported.min { a, b in
            abs((all.firstIndex(of: a) ?? 0) - r) < abs((all.firstIndex(of: b) ?? 0) - r)
        }
    }
}

/// Auto model routing tiers (used only when the model is "auto").
enum AutoTierOption {
    static let all = ["fast", "efficiency", "balance", "intelligence"]
    static func label(_ t: String) -> String {
        switch t {
        case "": return "Default"
        case "fast": return "Fast"
        case "efficiency": return "Efficient"
        case "balance": return "Balanced"
        case "intelligence": return "Smartest"
        default: return t.capitalized
        }
    }
    static func icon(_ t: String) -> String {
        switch t {
        case "fast": return "hare"
        case "efficiency": return "leaf"
        case "balance": return "scalemass"
        case "intelligence": return "brain"
        default: return "wand.and.sparkles"
        }
    }
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

    /// Sentinel id prefix for BYOK model options. The suffix is the model's UUID.
    static let byokPrefix = "byok:"

    @Published var models: [ModelOption] = [ModelOption(id: "auto", name: "Auto")]
    @Published var bridgeReady = false
    @Published var lastError: String?

    /// The model list shown in pickers: the configured BYOK models first,
    /// followed by the Copilot models. Keeps the General settings picker and the
    /// Edit window picker consistent.
    var availableModels: [ModelOption] {
        let s = SettingsStore.shared.settings
        let byok = s.byokModels.filter(\.isConfigured).map {
            ModelOption(id: $0.optionID, name: "\($0.displayName) (BYOK)")
        }
        return byok + models
    }

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutBuffer = Data()
    private var handles: [String: RunHandle] = [:]
    private var runTimers: [String: Timer] = [:]
    private var stderrLog: FileHandle?
    private var modelsCompletion: ((Result<[ModelOption], Error>) -> Void)?
    private var pingCompletion: ((Result<Void, Error>) -> Void)?

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
        env["POPSIDEKICK_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        // Ensure node and copilot can be found on PATH.
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let existing = env["PATH"] ?? ""
        env["PATH"] = (extraPaths + [existing]).joined(separator: ":")
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = Self.openStderrLog().map { handle -> FileHandle in
            self.stderrLog = handle
            return handle
        } ?? FileHandle.nullDevice

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
        runTimers.values.forEach { $0.invalidate() }
        runTimers.removeAll()
        try? stderrLog?.close()
        stderrLog = nil
    }

    private func handleTermination() {
        bridgeReady = false
        process = nil
        stdinPipe = nil
        runTimers.values.forEach { $0.invalidate() }
        runTimers.removeAll()
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

    /// Verifies a BYOK model by creating a session against its provider and
    /// sending a trivial prompt. Reports success or the provider's error message.
    func ping(model byok: BYOKModel, completion: @escaping (Result<Void, Error>) -> Void) {
        ensureStarted()
        pingCompletion = completion
        var payload: [String: Any] = [
            "cmd": "ping",
            "id": "ping",
            "prompt": "Reply with: OK",
            "autoApproveTools": true,
            "timeoutMs": 120000,
        ]
        let name = byok.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { payload["model"] = name }
        if let provider = Self.byokProviderPayload(byok) { payload["provider"] = provider }
        send(payload)
        // Backstop in case the bridge never replies. Kept longer than the bridge
        // timeout so the provider's own message wins when it does respond.
        DispatchQueue.main.asyncAfter(deadline: .now() + 135) { [weak self] in
            guard let self, let pending = self.pingCompletion else { return }
            self.pingCompletion = nil
            pending(.failure(NSError(domain: "PopSidekick", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for the provider."])))
        }
    }

    /// Builds the SDK `provider` config dictionary for a BYOK model, or nil when
    /// no base URL is set.
    static func byokProviderPayload(_ m: BYOKModel) -> [String: Any]? {
        let base = m.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        var p: [String: Any] = ["type": m.type.sdkType, "baseUrl": base]
        let key = m.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let bearer = m.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if m.type.allowsBearerToken, !bearer.isEmpty {
            p["bearerToken"] = bearer
        } else if m.type.requiresAPIKey, !key.isEmpty {
            p["apiKey"] = key
        }
        if m.type.supportsWireAPI {
            p["wireApi"] = m.wireAPI.rawValue
        }
        if m.type.isAzure {
            let version = m.azureAPIVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            if !version.isEmpty { p["azure"] = ["apiVersion": version] }
        }
        return p
    }

    @discardableResult
    func run(prompt: String, model: String, choices: Int, attachments: [[String: Any]]? = nil,
             reasoningEffort: String? = nil, autoTier: String? = nil) -> RunHandle {
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
            "autoApproveTools": settings.autoApproveTools,
        ]
        // When the user picked a configured BYOK model, route the run through its
        // provider; otherwise it's a Copilot model and needs no provider.
        Self.applyModelRouting(&payload, model: model, settings: settings)
        if payload["provider"] == nil {
            if model == "auto" {
                let tier = autoTier ?? settings.autoTier
                if !tier.isEmpty { payload["autoTier"] = tier }
            } else if let opt = models.first(where: { $0.id == model }),
                      let effort = ReasoningLevel.resolve(reasoningEffort ?? settings.reasoningEffort,
                                                          supported: opt.efforts) {
                payload["reasoningEffort"] = effort
            }
        }
        if let attachments, !attachments.isEmpty {
            payload["attachments"] = attachments
        }
        let timeoutSeconds = max(0, settings.runTimeoutSeconds)
        if timeoutSeconds > 0 {
            payload["timeoutMs"] = timeoutSeconds * 1000
        }
        if !settings.workingFolderPath.isEmpty {
            payload["workingDirectory"] = SettingsStore.expand(settings.workingFolderPath)
        }
        if settings.useSkillsFolder, !settings.skillsFolderPath.isEmpty {
            payload["skillDirectories"] = [SettingsStore.expand(settings.skillsFolderPath)]
            payload["enableConfigDiscovery"] = true
        }
        if settings.useMCP {
            if let servers = Self.loadMCPServers(settings: settings) { payload["mcpServers"] = servers }
            // Let the SDK skip disabled servers, including ones found via config discovery.
            let disabled = settings.mcpServerToggles.filter { !$0.enabled }.map(\.name)
            if !disabled.isEmpty { payload["disabledMcpServers"] = disabled }
        }
        send(payload)
        // Swift-side backstop: if the bridge itself hangs (no event at all),
        // fail the run after the timeout plus a grace period.
        if timeoutSeconds > 0 {
            scheduleTimeout(for: id, seconds: TimeInterval(timeoutSeconds) + 15)
        }
        return handle
    }

    /// Resolves a picker model id into the `model`/`provider` payload keys.
    /// BYOK ids route through the stored provider; Copilot ids pass through.
    private static func applyModelRouting(_ payload: inout [String: Any], model: String, settings: AppSettings) {
        payload["model"] = model
        guard model.hasPrefix(byokPrefix) else { return }
        if let byok = settings.byokModels.first(where: { $0.optionID == model }),
           byok.isConfigured, let provider = byokProviderPayload(byok) {
            payload["provider"] = provider
            payload["model"] = byok.model.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            payload["model"] = "auto"
        }
    }

    private func scheduleTimeout(for id: String, seconds: TimeInterval) {
        runTimers[id]?.invalidate()
        runTimers[id] = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fireTimeout(id) }
        }
    }

    private func clearTimeout(for id: String) {
        runTimers[id]?.invalidate()
        runTimers[id] = nil
    }

    /// Extends the watchdog when activity arrives (streaming deltas/results).
    private func refreshTimeout(for id: String) {
        guard runTimers[id] != nil else { return }
        let seconds = max(0, SettingsStore.shared.settings.runTimeoutSeconds)
        guard seconds > 0 else { return }
        scheduleTimeout(for: id, seconds: TimeInterval(seconds) + 15)
    }

    private func fireTimeout(_ id: String) {
        guard let handle = handles[id] else { return }
        clearTimeout(for: id)
        send(["cmd": "cancel", "id": id])
        handles[id] = nil
        handle.onError("Timed out waiting for a response.")
    }

    func cancel(_ handle: RunHandle) {
        send(["cmd": "cancel", "id": handle.id])
        handles[handle.id] = nil
        clearTimeout(for: handle.id)
    }

    private func ensureStarted() {
        if process == nil { start() }
    }

    /// Path to a discovered Node.js executable, or nil if none is found.
    /// Used by onboarding to verify the runtime is available.
    static func nodeExecutablePath() -> String? { locateNode()?.path }

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
        // Guard against a runaway line with no newline (bridge events are small).
        if stdoutBuffer.count > 32 * 1024 * 1024, stdoutBuffer.firstIndex(of: 0x0A) == nil {
            stdoutBuffer.removeAll(keepingCapacity: false)
            return
        }
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
                return ModelOption(id: id, name: dict["name"] as? String ?? id,
                                   efforts: dict["efforts"] as? [String] ?? [],
                                   defaultEffort: dict["defaultEffort"] as? String)
            }
            if !opts.contains(where: { $0.id == "auto" }) {
                opts.insert(ModelOption(id: "auto", name: "Auto"), at: 0)
            }
            models = opts
            modelsCompletion?(.success(opts))
            modelsCompletion = nil
        case "pong":
            pingCompletion?(.success(()))
            pingCompletion = nil
        case "delta":
            if let id = event["id"] as? String, let h = handles[id] {
                refreshTimeout(for: id)
                h.onDelta(event["choice"] as? Int ?? 0, event["text"] as? String ?? "")
            }
        case "result":
            if let id = event["id"] as? String, let h = handles[id] {
                refreshTimeout(for: id)
                h.onResult(event["choice"] as? Int ?? 0, event["text"] as? String ?? "")
            }
        case "done":
            if let id = event["id"] as? String, let h = handles[id] {
                clearTimeout(for: id)
                h.onDone()
                handles[id] = nil
            }
        case "error":
            let message = event["message"] as? String ?? "Unknown error"
            if let id = event["id"] as? String, let h = handles[id] {
                clearTimeout(for: id)
                h.onError(message)
                handles[id] = nil
            } else if (event["id"] as? String) == "ping" {
                pingCompletion?(.failure(NSError(domain: "PopSidekick", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: message])))
                pingCompletion = nil
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

    /// Opens (creating/truncating if oversized) the bridge stderr log so child
    /// process errors are captured for diagnostics instead of discarded.
    private static func openStderrLog() -> FileHandle? {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PopSidekick", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("bridge.log")
        // Truncate if the previous log grew past ~512 KB.
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? UInt64, size > 512 * 1024 {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        // May contain prompts or provider errors; keep it private.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }

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

    /// Loads the MCP servers from the configured mcp.json file. Disabled ones are
    /// sent separately as `disabledMcpServers` so the SDK doesn't start them.
    private static func loadMCPServers(settings: AppSettings) -> [String: Any]? {
        let path = SettingsStore.expand(settings.mcpConfigPath)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // Support { "mcpServers": {...} }, { "servers": {...} } (VS Code style),
        // and a bare object of servers.
        let servers = (json["mcpServers"] as? [String: Any])
            ?? (json["servers"] as? [String: Any])
            ?? json
        return servers.isEmpty ? nil : servers
    }
}

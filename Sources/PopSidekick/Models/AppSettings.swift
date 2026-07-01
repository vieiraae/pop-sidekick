import Foundation

/// A single MCP server entry the user can enable/disable.
struct MCPServerToggle: Codable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var enabled: Bool
}

/// A web search engine the user can search the selection with. `urlTemplate`
/// contains a `%s` placeholder that is replaced with the percent-encoded query.
struct SearchEngine: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var urlTemplate: String = ""

    /// Built-in engines, seeded on first launch. Stable ids so a saved
    /// `defaultSearchEngineID` keeps matching across launches.
    static let defaults: [SearchEngine] = [
        SearchEngine(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                     name: "Google", urlTemplate: "https://www.google.com/search?q=%s"),
        SearchEngine(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                     name: "Bing", urlTemplate: "https://www.bing.com/search?q=%s"),
    ]

    /// True when the engine has a usable name and a template with a `%s`.
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && urlTemplate.contains("%s")
    }

    /// Builds a search URL for `query`, percent-encoding it into the template.
    func url(for query: String) -> URL? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        return URL(string: urlTemplate.replacingOccurrences(of: "%s", with: encoded))
    }
}

/// Where models come from: GitHub Copilot (default) or a user-supplied provider.
enum ModelSource: String, Codable, CaseIterable, Identifiable {
    case copilot
    case byok
    var id: String { rawValue }
    var label: String { self == .copilot ? "Copilot Models" : "Bring Your Own Model" }
}

/// BYOK provider, mirroring the Copilot SDK "supported providers" table. Several
/// entries share the same SDK `provider.type` value but differ in which
/// properties they need.
enum BYOKProviderType: String, Codable, CaseIterable, Identifiable {
    case openai
    case azure
    case anthropic
    case ollama
    case foundryLocal
    case openaiCompatible

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openai: return "OpenAI"
        case .azure: return "Azure OpenAI / AI Foundry"
        case .anthropic: return "Anthropic"
        case .ollama: return "Ollama (local)"
        case .foundryLocal: return "Microsoft Foundry Local"
        case .openaiCompatible: return "Other OpenAI-compatible"
        }
    }

    /// The value sent as `provider.type` to the SDK.
    var sdkType: String {
        switch self {
        case .azure: return "azure"
        case .anthropic: return "anthropic"
        default: return "openai"
        }
    }

    /// Local providers run on localhost and don't require credentials.
    var isLocal: Bool { self == .ollama || self == .foundryLocal }
    var requiresAPIKey: Bool { !isLocal }
    var allowsBearerToken: Bool { self == .openai || self == .openaiCompatible }
    var supportsWireAPI: Bool { sdkType == "openai" }
    var isAzure: Bool { self == .azure }

    /// A sensible default endpoint, or "" when the user must supply their own.
    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        case .ollama: return "http://localhost:11434/v1"
        case .azure, .foundryLocal, .openaiCompatible: return ""
        }
    }

    var baseURLPlaceholder: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .azure: return "https://my-resource.openai.azure.com"
        case .anthropic: return "https://api.anthropic.com"
        case .ollama: return "http://localhost:11434/v1"
        case .foundryLocal: return "http://localhost:<PORT>/v1"
        case .openaiCompatible: return "https://your-endpoint/v1"
        }
    }

    var baseURLHelp: String {
        switch self {
        case .openai:
            return "Full endpoint including the version path, e.g. https://api.openai.com/v1."
        case .azure:
            return "Just the host — the SDK builds the path. Do not include /openai/v1."
        case .anthropic:
            return "Anthropic API base, typically https://api.anthropic.com."
        case .ollama:
            return "Local Ollama endpoint. No API key required."
        case .foundryLocal:
            return "Foundry Local uses a dynamic port — run `foundry service status` to find it. No API key required."
        case .openaiCompatible:
            return "Any OpenAI-compatible endpoint (vLLM, LiteLLM, etc.), including the version path."
        }
    }
}

/// Wire API format for OpenAI-compatible providers.
enum WireAPI: String, Codable, CaseIterable, Identifiable {
    case completions
    case responses
    var id: String { rawValue }
    var label: String { self == .completions ? "Chat Completions" : "Responses" }
}

/// A single bring-your-own-model entry: a model plus the provider config needed
/// to reach it. Users can configure any number of these.
struct BYOKModel: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    /// Optional friendly name; falls back to the model id for display.
    var name: String = ""
    var type: BYOKProviderType = .openai
    /// The model / deployment name the provider expects (required).
    var model: String = ""
    var baseURL: String = ""
    var apiKey: String = ""
    var bearerToken: String = ""
    var wireAPI: WireAPI = .completions
    var azureAPIVersion: String = "2024-10-21"

    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? model.trimmingCharacters(in: .whitespaces) : n
    }

    /// True when there is enough to actually reach the model.
    var isConfigured: Bool {
        !model.trimmingCharacters(in: .whitespaces).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Stable id used as the model option / selection value in pickers.
    var optionID: String { "byok:" + id.uuidString }
}

/// Persisted application settings. Stored as JSON in Application Support.
struct AppSettings: Codable {
    var copilotPath: String = "/opt/homebrew/bin/copilot"
    var model: String = "auto"

    // Whether the BYOK section is expanded/in use (also used to remember intent).
    var modelSource: ModelSource = .copilot
    /// User-configured bring-your-own models, surfaced in the model pickers.
    var byokModels: [BYOKModel] = []

    var systemMessage: String = "You are a precise writing assistant. Transform the user's text as instructed and reply with only the resulting text, no preamble, commentary, or code fences unless the requested format requires them."
    var maxHistoryItems: Int = 50
    var defaultChoices: Int = 1

    /// Configurable web search engines and the id of the default one (used by
    /// the search button; the rest appear in its dropdown).
    var searchEngines: [SearchEngine] = SearchEngine.defaults
    var defaultSearchEngineID: UUID? = SearchEngine.defaults.first?.id
    /// All tasks, seeded with the built-in defaults on first launch. Users can
    /// edit, delete, or add tasks freely.
    var tasks: [TaskDef] = TaskDef.builtins

    // Advanced
    var useSkillsFolder: Bool = false
    var skillsFolderPath: String = ""
    var useMCP: Bool = false
    var mcpConfigPath: String = "~/.copilot/mcp-config.json"
    var mcpServerToggles: [MCPServerToggle] = []

    // Behavior
    var launchAtLogin: Bool = false
    var showPopupAutomatically: Bool = true
    /// Global shortcut to open the clipboard history popup from anywhere.
    var clipboardHotkey: Hotkey? = nil
    /// Seconds of inactivity before an AI run is aborted automatically.
    var runTimeoutSeconds: Int = 120
    /// Whether the bridge auto-approves tool/MCP/skill permission requests.
    /// When false, tool use is rejected (the headless bridge can't prompt).
    /// Defaults to OFF: AI prompts are built from untrusted selected text, so
    /// auto-approving tool execution would be a prompt-injection risk.
    var autoApproveTools: Bool = false
    /// Set once the first-run onboarding has been completed/dismissed.
    var hasCompletedOnboarding: Bool = false

    // Persisted Edit-panel selections. `nil` means "unset" — the option is only
    // applied to the prompt when it has a value.
    var editTaskID: String? = nil
    var editTone: Tone? = nil
    var editFormat: OutputFormat? = nil
    var editLength: Length? = nil

    /// All tasks available in dropdowns.
    var allTasks: [TaskDef] { tasks }
    /// Tasks surfaced as dedicated buttons in the compact action bar.
    var popupTasks: [TaskDef] { tasks.filter(\.showInPopup) }

    /// The engine the search button uses: the saved default, or the first one.
    var defaultSearchEngine: SearchEngine? {
        if let id = defaultSearchEngineID,
           let match = searchEngines.first(where: { $0.id == id }) {
            return match
        }
        return searchEngines.first
    }

    /// True when at least one BYOK model is usable.
    var hasBYOKModels: Bool { byokModels.contains(where: \.isConfigured) }

    init() {}

    enum CodingKeys: String, CodingKey {
        case copilotPath, model, systemMessage, maxHistoryItems, defaultChoices
        case searchEngines, defaultSearchEngineID
        case modelSource, byokModels
        // Legacy single-model keys, kept for one-time migration.
        case byokType, byokBaseURL, byokAPIKey, byokBearerToken, byokWireAPI, byokAzureAPIVersion, byokModel
        case tasks, customTasks
        case useSkillsFolder, skillsFolderPath, useMCP, mcpConfigPath, mcpServerToggles
        case launchAtLogin, showPopupAutomatically, runTimeoutSeconds, autoApproveTools, hasCompletedOnboarding
        case clipboardHotkey
        case editTaskID, editTone, editFormat, editLength
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        copilotPath = v(.copilotPath, copilotPath)
        model = v(.model, model)
        modelSource = v(.modelSource, modelSource)

        // Migrate the old single BYOK config into the new list on first load.
        if let stored = ((try? c.decodeIfPresent([BYOKModel].self, forKey: .byokModels)) ?? nil) {
            byokModels = stored
        } else {
            let legacyModel = v(.byokModel, "")
            let legacyBase = v(.byokBaseURL, "")
            if !legacyModel.isEmpty || !legacyBase.isEmpty {
                var m = BYOKModel()
                m.type = v(.byokType, BYOKProviderType.openai)
                m.model = legacyModel
                m.baseURL = legacyBase
                m.apiKey = v(.byokAPIKey, "")
                m.bearerToken = v(.byokBearerToken, "")
                m.wireAPI = v(.byokWireAPI, WireAPI.completions)
                m.azureAPIVersion = v(.byokAzureAPIVersion, "2024-10-21")
                byokModels = [m]
                // Old default-model sentinel now points at this migrated entry.
                if model == "__byok__" { model = m.optionID }
            }
        }
        systemMessage = v(.systemMessage, systemMessage)
        maxHistoryItems = v(.maxHistoryItems, maxHistoryItems)
        defaultChoices = v(.defaultChoices, defaultChoices)
        searchEngines = v(.searchEngines, searchEngines)
        defaultSearchEngineID = ((try? c.decodeIfPresent(UUID.self, forKey: .defaultSearchEngineID)) ?? nil)

        // Migration: older settings stored only user-defined `customTasks`
        // alongside hard-coded built-ins. Seed the new unified `tasks` list with
        // the built-in defaults plus any previously saved custom tasks.
        if let stored = ((try? c.decodeIfPresent([TaskDef].self, forKey: .tasks)) ?? nil) {
            tasks = stored
        } else {
            let legacy = ((try? c.decodeIfPresent([TaskDef].self, forKey: .customTasks)) ?? nil) ?? []
            tasks = TaskDef.builtins + legacy
        }

        useSkillsFolder = v(.useSkillsFolder, useSkillsFolder)
        skillsFolderPath = v(.skillsFolderPath, skillsFolderPath)
        useMCP = v(.useMCP, useMCP)
        mcpConfigPath = v(.mcpConfigPath, mcpConfigPath)
        mcpServerToggles = v(.mcpServerToggles, mcpServerToggles)
        launchAtLogin = v(.launchAtLogin, launchAtLogin)
        showPopupAutomatically = v(.showPopupAutomatically, showPopupAutomatically)
        clipboardHotkey = ((try? c.decodeIfPresent(Hotkey.self, forKey: .clipboardHotkey)) ?? nil)
        runTimeoutSeconds = v(.runTimeoutSeconds, runTimeoutSeconds)
        autoApproveTools = v(.autoApproveTools, autoApproveTools)
        hasCompletedOnboarding = v(.hasCompletedOnboarding, hasCompletedOnboarding)
        editTaskID = ((try? c.decodeIfPresent(String.self, forKey: .editTaskID)) ?? nil)
        editTone = ((try? c.decodeIfPresent(Tone.self, forKey: .editTone)) ?? nil)
        editFormat = ((try? c.decodeIfPresent(OutputFormat.self, forKey: .editFormat)) ?? nil)
        editLength = ((try? c.decodeIfPresent(Length.self, forKey: .editLength)) ?? nil)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(copilotPath, forKey: .copilotPath)
        try c.encode(model, forKey: .model)
        try c.encode(modelSource, forKey: .modelSource)
        try c.encode(byokModels, forKey: .byokModels)
        try c.encode(systemMessage, forKey: .systemMessage)
        try c.encode(maxHistoryItems, forKey: .maxHistoryItems)
        try c.encode(defaultChoices, forKey: .defaultChoices)
        try c.encode(searchEngines, forKey: .searchEngines)
        try c.encodeIfPresent(defaultSearchEngineID, forKey: .defaultSearchEngineID)
        try c.encode(tasks, forKey: .tasks)
        try c.encode(useSkillsFolder, forKey: .useSkillsFolder)
        try c.encode(skillsFolderPath, forKey: .skillsFolderPath)
        try c.encode(useMCP, forKey: .useMCP)
        try c.encode(mcpConfigPath, forKey: .mcpConfigPath)
        try c.encode(mcpServerToggles, forKey: .mcpServerToggles)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(showPopupAutomatically, forKey: .showPopupAutomatically)
        try c.encodeIfPresent(clipboardHotkey, forKey: .clipboardHotkey)
        try c.encode(runTimeoutSeconds, forKey: .runTimeoutSeconds)
        try c.encode(autoApproveTools, forKey: .autoApproveTools)
        try c.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
        try c.encodeIfPresent(editTaskID, forKey: .editTaskID)
        try c.encodeIfPresent(editTone, forKey: .editTone)
        try c.encodeIfPresent(editFormat, forKey: .editFormat)
        try c.encodeIfPresent(editLength, forKey: .editLength)
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var settings: AppSettings {
        didSet {
            save()
            if settings.launchAtLogin != oldValue.launchAtLogin {
                LoginItem.apply(enabled: settings.launchAtLogin)
            }
        }
    }

    private let url: URL

    private init() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PopSidekick", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("settings.json")

        if let data = try? Data(contentsOf: url) {
            do {
                self.settings = try JSONDecoder().decode(AppSettings.self, from: data)
            } catch {
                // Preserve the unreadable file for inspection instead of losing it.
                let backup = url.appendingPathExtension("corrupt")
                try? fm.removeItem(at: backup)
                try? fm.moveItem(at: url, to: backup)
                Diag.log("SettingsStore: failed to decode settings.json: \(error); backed up")
                self.settings = AppSettings()
            }
        } else {
            self.settings = AppSettings()
        }
        // Tighten permissions on a pre-existing settings file (may hold BYOK
        // secrets) written before this hardening.
        if fm.fileExists(atPath: url.path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
        // Settings may hold BYOK API keys/tokens — restrict to the owner.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Expands a leading ~ to the user's home directory.
    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

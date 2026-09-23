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
/// How a mouse drag interacts with FocusTrace drawing.
/// How FocusTrace draws the magnified cursor.
enum FocusTraceCursorShape: String, Codable, CaseIterable, Identifiable {
    /// The macOS arrow image, magnified (color doesn't apply).
    case system
    case arrow, hand, dot, ring, crosshair
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System arrow"
        case .arrow: return "Arrow"
        case .hand: return "Pointing hand"
        case .dot: return "Dot"
        case .ring: return "Ring"
        case .crosshair: return "Crosshair"
        }
    }
    var symbol: String {
        switch self {
        case .system, .arrow: return "cursorarrow"
        case .hand: return "hand.point.up.left.fill"
        case .dot: return "circle.fill"
        case .ring: return "circle"
        case .crosshair: return "plus"
        }
    }
}

enum FocusTraceDrawMode: String, Codable, CaseIterable, Identifiable {
    /// Drags draw and still reach the app underneath.
    case passThrough
    /// Drags only draw; apps underneath don't receive clicks or drags.
    case capture
    /// Hold ⌥ while dragging to draw; other drags are unaffected.
    case modifier
    var id: String { rawValue }
    var label: String {
        switch self {
        case .passThrough: return "Pass-through"
        case .capture: return "Capture"
        case .modifier: return "Hold ⌥ to draw"
        }
    }
    var detail: String {
        switch self {
        case .passThrough: return "Dragging draws a trace and still reaches the app underneath."
        case .capture: return "Dragging only draws. Apps underneath don't receive clicks or drags while FocusTrace is on."
        case .modifier: return "Hold ⌥ Option and drag to draw. Normal clicks and drags work as usual."
        }
    }
}

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
    /// Default reasoning effort ("" = the model's own default).
    var reasoningEffort: String = ""
    /// Auto model routing tier used when the model is "auto" ("" = runtime default).
    var autoTier: String = ""

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
    var workingFolderPath: String = ""
    var useSkillsFolder: Bool = false
    var skillsFolderPath: String = ""
    var useMCP: Bool = false
    var mcpConfigPath: String = "~/.copilot/mcp-config.json"
    var mcpServerToggles: [MCPServerToggle] = []

    // FocusTrace
    var focusTraceHotkey: Hotkey? = nil
    /// Cursor magnification (1 = normal size).
    var focusTraceCursorScale: Double = 2.5
    var focusTraceShowHalo: Bool = true
    var focusTraceColorHex: String = "#FF2D95"
    /// Flow the trace through a spectrum of colors instead of a single color.
    var focusTraceMulticolor: Bool = true
    var focusTraceLineWidth: Double = 10
    /// Seconds before a traced point fades out completely.
    var focusTraceFadeSeconds: Double = 1.6
    var focusTraceDrawMode: FocusTraceDrawMode = .passThrough
    var focusTraceCursorShape: FocusTraceCursorShape = .system
    var focusTraceCursorColorHex: String = "#FF2D95"
    /// Rough loops snap to circles/rectangles, straight-ish strokes to lines,
    /// and ⇧-drags draw arrows.
    var focusTraceSnapShapes: Bool = true
    /// Keep strokes on screen instead of fading them (⌘Z undo, ⌘⌫ clear).
    var focusTracePersistentInk: Bool = false
    var focusTraceRipples: Bool = false
    /// Final ripple radius in points.
    var focusTraceRippleSize: Double = 10
    var focusTraceSpotlight: Bool = false
    var focusTraceSpotlightRadius: Double = 150
    /// How dark the area outside the spotlight gets, 0–1.
    var focusTraceSpotlightDim: Double = 0.55
    /// Pinch on the trackpad to zoom where the cursor is.
    var focusTraceMagnifier: Bool = true
    var focusTraceMagnifierSize: Double = 240
    var focusTraceBlackHotkey: Hotkey? = AppSettings.defaultBlackHotkey
    var focusTraceWhiteHotkey: Hotkey? = AppSettings.defaultWhiteHotkey
    /// Which screen(s) the blank-screen shortcuts cover: "all", "pointer"
    /// (the screen with the cursor), or a display's localized name.
    var focusTraceBlankTarget: String = "all"

    static let defaultBlackHotkey = Hotkey(keyCode: 11, modifiers: UInt32(Hotkey.controlKeyMask | Hotkey.optionKeyMask))
    static let defaultWhiteHotkey = Hotkey(keyCode: 13, modifiers: UInt32(Hotkey.controlKeyMask | Hotkey.optionKeyMask))

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
    /// Quick replace actions open the result as a reviewable diff instead of
    /// writing it straight back over the selection.
    var reviewChangesBeforeReplace: Bool = false
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
        case copilotPath, model, reasoningEffort, autoTier, systemMessage, maxHistoryItems, defaultChoices
        case searchEngines, defaultSearchEngineID
        case modelSource, byokModels
        // Legacy single-model keys, kept for one-time migration.
        case byokType, byokBaseURL, byokAPIKey, byokBearerToken, byokWireAPI, byokAzureAPIVersion, byokModel
        case tasks, customTasks
        case useSkillsFolder, skillsFolderPath, useMCP, mcpConfigPath, mcpServerToggles, workingFolderPath
        case launchAtLogin, showPopupAutomatically, runTimeoutSeconds, autoApproveTools, hasCompletedOnboarding
        case reviewChangesBeforeReplace
        case clipboardHotkey
        case focusTraceHotkey, focusTraceCursorScale, focusTraceShowHalo, focusTraceColorHex
        case focusTraceMulticolor, focusTraceLineWidth, focusTraceFadeSeconds, focusTraceDrawMode
        case focusTraceSnapShapes, focusTracePersistentInk, focusTraceRipples, focusTraceSpotlight
        case focusTraceRippleSize, focusTraceSpotlightRadius, focusTraceSpotlightDim, focusTraceMagnifier, focusTraceMagnifierSize
        case focusTraceBlackHotkey, focusTraceWhiteHotkey, focusTraceBlankTarget
        case focusTraceCursorShape, focusTraceCursorColorHex
        case editTaskID, editTone, editFormat, editLength
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        copilotPath = v(.copilotPath, copilotPath)
        model = v(.model, model)
        reasoningEffort = v(.reasoningEffort, reasoningEffort)
        autoTier = v(.autoTier, autoTier)
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
        workingFolderPath = v(.workingFolderPath, workingFolderPath)
        useMCP = v(.useMCP, useMCP)
        mcpConfigPath = v(.mcpConfigPath, mcpConfigPath)
        mcpServerToggles = v(.mcpServerToggles, mcpServerToggles)
        launchAtLogin = v(.launchAtLogin, launchAtLogin)
        showPopupAutomatically = v(.showPopupAutomatically, showPopupAutomatically)
        clipboardHotkey = ((try? c.decodeIfPresent(Hotkey.self, forKey: .clipboardHotkey)) ?? nil)
        focusTraceHotkey = ((try? c.decodeIfPresent(Hotkey.self, forKey: .focusTraceHotkey)) ?? nil)
        focusTraceCursorScale = v(.focusTraceCursorScale, focusTraceCursorScale)
        focusTraceShowHalo = v(.focusTraceShowHalo, focusTraceShowHalo)
        focusTraceColorHex = v(.focusTraceColorHex, focusTraceColorHex)
        focusTraceMulticolor = v(.focusTraceMulticolor, focusTraceMulticolor)
        focusTraceLineWidth = v(.focusTraceLineWidth, focusTraceLineWidth)
        focusTraceFadeSeconds = v(.focusTraceFadeSeconds, focusTraceFadeSeconds)
        focusTraceDrawMode = v(.focusTraceDrawMode, focusTraceDrawMode)
        focusTraceSnapShapes = v(.focusTraceSnapShapes, focusTraceSnapShapes)
        focusTracePersistentInk = v(.focusTracePersistentInk, focusTracePersistentInk)
        focusTraceRipples = v(.focusTraceRipples, focusTraceRipples)
        focusTraceSpotlight = v(.focusTraceSpotlight, focusTraceSpotlight)
        focusTraceSpotlightRadius = v(.focusTraceSpotlightRadius, focusTraceSpotlightRadius)
        focusTraceSpotlightDim = v(.focusTraceSpotlightDim, focusTraceSpotlightDim)
        focusTraceRippleSize = v(.focusTraceRippleSize, focusTraceRippleSize)
        focusTraceMagnifier = v(.focusTraceMagnifier, focusTraceMagnifier)
        focusTraceMagnifierSize = v(.focusTraceMagnifierSize, focusTraceMagnifierSize)
        focusTraceBlankTarget = v(.focusTraceBlankTarget, focusTraceBlankTarget)
        focusTraceCursorShape = v(.focusTraceCursorShape, focusTraceCursorShape)
        focusTraceCursorColorHex = v(.focusTraceCursorColorHex, focusTraceCursorColorHex)
        // A stored null means the user cleared the shortcut; absence means default.
        if c.contains(.focusTraceBlackHotkey) {
            focusTraceBlackHotkey = (try? c.decodeIfPresent(Hotkey.self, forKey: .focusTraceBlackHotkey)) ?? nil
        }
        if c.contains(.focusTraceWhiteHotkey) {
            focusTraceWhiteHotkey = (try? c.decodeIfPresent(Hotkey.self, forKey: .focusTraceWhiteHotkey)) ?? nil
        }
        runTimeoutSeconds = v(.runTimeoutSeconds, runTimeoutSeconds)
        autoApproveTools = v(.autoApproveTools, autoApproveTools)
        reviewChangesBeforeReplace = v(.reviewChangesBeforeReplace, reviewChangesBeforeReplace)
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
        try c.encode(reasoningEffort, forKey: .reasoningEffort)
        try c.encode(autoTier, forKey: .autoTier)
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
        try c.encode(workingFolderPath, forKey: .workingFolderPath)
        try c.encode(useMCP, forKey: .useMCP)
        try c.encode(mcpConfigPath, forKey: .mcpConfigPath)
        try c.encode(mcpServerToggles, forKey: .mcpServerToggles)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(showPopupAutomatically, forKey: .showPopupAutomatically)
        try c.encodeIfPresent(clipboardHotkey, forKey: .clipboardHotkey)
        try c.encodeIfPresent(focusTraceHotkey, forKey: .focusTraceHotkey)
        try c.encode(focusTraceCursorScale, forKey: .focusTraceCursorScale)
        try c.encode(focusTraceShowHalo, forKey: .focusTraceShowHalo)
        try c.encode(focusTraceColorHex, forKey: .focusTraceColorHex)
        try c.encode(focusTraceMulticolor, forKey: .focusTraceMulticolor)
        try c.encode(focusTraceLineWidth, forKey: .focusTraceLineWidth)
        try c.encode(focusTraceFadeSeconds, forKey: .focusTraceFadeSeconds)
        try c.encode(focusTraceDrawMode, forKey: .focusTraceDrawMode)
        try c.encode(focusTraceSnapShapes, forKey: .focusTraceSnapShapes)
        try c.encode(focusTracePersistentInk, forKey: .focusTracePersistentInk)
        try c.encode(focusTraceRipples, forKey: .focusTraceRipples)
        try c.encode(focusTraceSpotlight, forKey: .focusTraceSpotlight)
        try c.encode(focusTraceSpotlightRadius, forKey: .focusTraceSpotlightRadius)
        try c.encode(focusTraceSpotlightDim, forKey: .focusTraceSpotlightDim)
        try c.encode(focusTraceRippleSize, forKey: .focusTraceRippleSize)
        try c.encode(focusTraceMagnifier, forKey: .focusTraceMagnifier)
        try c.encode(focusTraceMagnifierSize, forKey: .focusTraceMagnifierSize)
        try c.encode(focusTraceBlackHotkey, forKey: .focusTraceBlackHotkey)
        try c.encode(focusTraceWhiteHotkey, forKey: .focusTraceWhiteHotkey)
        try c.encode(focusTraceBlankTarget, forKey: .focusTraceBlankTarget)
        try c.encode(focusTraceCursorShape, forKey: .focusTraceCursorShape)
        try c.encode(focusTraceCursorColorHex, forKey: .focusTraceCursorColorHex)
        try c.encode(runTimeoutSeconds, forKey: .runTimeoutSeconds)
        try c.encode(autoApproveTools, forKey: .autoApproveTools)
        try c.encode(reviewChangesBeforeReplace, forKey: .reviewChangesBeforeReplace)
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

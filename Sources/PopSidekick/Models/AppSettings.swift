import Foundation

/// A single MCP server entry the user can enable/disable.
struct MCPServerToggle: Codable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var enabled: Bool
}

/// Persisted application settings. Stored as JSON in Application Support.
struct AppSettings: Codable {
    var copilotPath: String = "/opt/homebrew/bin/copilot"
    var model: String = "auto"
    var systemMessage: String = "You are a precise writing assistant. Transform the user's text as instructed and reply with only the resulting text, no preamble, commentary, or code fences unless the requested format requires them."
    var maxHistoryItems: Int = 50
    var defaultChoices: Int = 1
    var customTasks: [TaskDef] = []

    // Advanced
    var useSkillsFolder: Bool = false
    var skillsFolderPath: String = ""
    var useMCP: Bool = false
    var mcpConfigPath: String = "~/.copilot/mcp-config.json"
    var mcpServerToggles: [MCPServerToggle] = []

    // Behavior
    var launchAtLogin: Bool = false
    var showPopupAutomatically: Bool = true

    // Persisted Edit-panel selections. `nil` means "unset" — the option is only
    // applied to the prompt when it has a value.
    var editTaskID: String? = nil
    var editTone: Tone? = nil
    var editFormat: OutputFormat? = nil
    var editLength: Length? = nil

    /// All tasks available in dropdowns: built-ins first, then custom.
    var allTasks: [TaskDef] { TaskDef.builtins + customTasks }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var settings: AppSettings {
        didSet { save() }
    }

    private let url: URL

    private init() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PopSidekick", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("settings.json")

        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = AppSettings()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Expands a leading ~ to the user's home directory.
    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

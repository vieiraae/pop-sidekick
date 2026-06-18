import SwiftUI
import AppKit

/// Multi-tab settings window content.
struct SettingsView: View {
    @ObservedObject var store = SettingsStore.shared
    @ObservedObject var copilot = CopilotService.shared

    var body: some View {
        TabView {
            GeneralSettings(store: store, copilot: copilot)
                .tabItem { Label("General", systemImage: "gearshape") }
            TasksSettings(store: store)
                .tabItem { Label("Tasks", systemImage: "wand.and.stars") }
            AdvancedSettings(store: store)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 540, height: 460)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var copilot: CopilotService
    @State private var accessibilityTrusted = AccessibilityService.isTrusted

    var body: some View {
        Form {
            Section("Permissions") {
                HStack(spacing: 10) {
                    Image(systemName: accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(accessibilityTrusted ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility")
                        Text(accessibilityTrusted
                             ? "Granted — Pop Sidekick can detect selected text."
                             : "Required to detect selected text across apps.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !accessibilityTrusted {
                        Button("Grant…") { grantAccessibility() }
                    }
                }
            }
            Section("Copilot") {
                HStack {
                    TextField("Copilot CLI path", text: $store.settings.copilotPath)
                    Button("Browse…") { pickFile(into: \.copilotPath) }
                }
                Picker("Default model", selection: $store.settings.model) {
                    ForEach(copilot.models) { m in Text(m.name).tag(m.id) }
                }
                Button("Refresh models") { copilot.refreshModels() }
                    .controlSize(.small)
            }
            Section("Behavior") {
                Toggle("Show popup automatically on selection", isOn: $store.settings.showPopupAutomatically)
                Stepper("Clipboard history: \(store.settings.maxHistoryItems) items",
                        value: $store.settings.maxHistoryItems, in: 5...500, step: 5)
                Stepper("Default result choices: \(store.settings.defaultChoices)",
                        value: $store.settings.defaultChoices, in: 1...5)
            }
            Section("System message") {
                TextEditor(text: $store.settings.systemMessage)
                    .font(.system(size: 12))
                    .frame(height: 90)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            accessibilityTrusted = AccessibilityService.isTrusted
        }
    }

    private func grantAccessibility() {
        if !AccessibilityService.requestPermission() {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func pickFile(into keyPath: WritableKeyPath<AppSettings, String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            store.settings[keyPath: keyPath] = url.path
        }
    }
}

private struct TasksSettings: View {
    @ObservedObject var store: SettingsStore
    @State private var selection: TaskDef.ID?

    var body: some View {
        VStack(alignment: .leading) {
            Text("Custom Tasks")
                .font(.headline)
            Text("Built-in tasks are always available. Add your own with an icon, name, and instruction.")
                .font(.caption).foregroundStyle(.secondary)

            List(selection: $selection) {
                ForEach($store.settings.customTasks) { $task in
                    HStack(spacing: 8) {
                        IconPickerButton(icon: $task.icon)
                        TextField("Name", text: $task.name)
                        Spacer()
                    }
                }
                .onDelete { store.settings.customTasks.remove(atOffsets: $0) }
            }
            .frame(height: 150)

            if let id = selection,
               let idx = store.settings.customTasks.firstIndex(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Instruction").font(.caption.weight(.semibold))
                    TextEditor(text: $store.settings.customTasks[idx].instruction)
                        .font(.system(size: 12))
                        .frame(height: 80)
                }
            }

            HStack {
                Button {
                    let task = TaskDef(name: "New Task", icon: "wand.and.stars",
                                       instruction: "Describe what to do with the text.")
                    store.settings.customTasks.append(task)
                    selection = task.id
                } label: { Label("Add Task", systemImage: "plus") }
                Spacer()
            }
        }
        .padding()
    }
}

private struct AdvancedSettings: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Skills") {
                Toggle("Use a skills folder", isOn: $store.settings.useSkillsFolder)
                HStack {
                    TextField("Skills folder path", text: $store.settings.skillsFolderPath)
                    Button("Browse…") { pickFolder(into: \.skillsFolderPath) }
                }
                .disabled(!store.settings.useSkillsFolder)
            }
            Section("MCP Servers") {
                Toggle("Enable MCP servers", isOn: $store.settings.useMCP)
                HStack {
                    TextField("mcp.json path", text: $store.settings.mcpConfigPath)
                    Button("Browse…") { pickFile(into: \.mcpConfigPath) }
                    Button("Reload") { reloadServers() }
                }
                .disabled(!store.settings.useMCP)

                if store.settings.useMCP {
                    ForEach($store.settings.mcpServerToggles) { $server in
                        Toggle(server.name, isOn: $server.enabled)
                    }
                    if store.settings.mcpServerToggles.isEmpty {
                        Text("No servers found. Set a valid mcp.json path and Reload.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { if store.settings.useMCP { reloadServers() } }
    }

    private func reloadServers() {
        let path = SettingsStore.expand(store.settings.mcpConfigPath)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let servers = (json["mcpServers"] as? [String: Any]) ?? json
        let names = servers.keys.sorted()
        let existing = Dictionary(uniqueKeysWithValues: store.settings.mcpServerToggles.map { ($0.name, $0.enabled) })
        store.settings.mcpServerToggles = names.map {
            MCPServerToggle(name: $0, enabled: existing[$0] ?? true)
        }
    }

    private func pickFolder(into keyPath: WritableKeyPath<AppSettings, String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            store.settings[keyPath: keyPath] = url.path
        }
    }

    private func pickFile(into keyPath: WritableKeyPath<AppSettings, String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            store.settings[keyPath: keyPath] = url.path
        }
    }
}

/// A button that shows the current SF Symbol and opens a searchable grid so the
/// user can pick an icon visually instead of typing a symbol name.
struct IconPickerButton: View {
    @Binding var icon: String
    @State private var showing = false
    @State private var query = ""

    private static let columns = Array(repeating: GridItem(.fixed(34), spacing: 4), count: 8)

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: icon.isEmpty ? "wand.and.stars" : icon)
                .font(.system(size: 14))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.bordered)
        .help("Choose icon")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(spacing: 8) {
                TextField("Search icons", text: $query)
                    .textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVGrid(columns: Self.columns, spacing: 4) {
                        ForEach(filtered, id: \.self) { name in
                            Button {
                                icon = name
                                showing = false
                            } label: {
                                Image(systemName: name)
                                    .font(.system(size: 15))
                                    .frame(width: 30, height: 28)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(name == icon ? Color.accentColor.opacity(0.25) : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(name)
                        }
                    }
                    .padding(2)
                }
                .frame(width: 318, height: 240)
                if filtered.isEmpty {
                    Text("No matching icons").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
    }

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? Self.icons : Self.icons.filter { $0.contains(q) }
    }

    /// Curated set of SF Symbols suited to text/AI task actions.
    static let icons: [String] = [
        "wand.and.stars", "sparkles", "checkmark.seal", "pencil.and.outline", "pencil",
        "text.alignleft", "text.justify", "text.append", "text.quote", "text.magnifyingglass",
        "textformat", "textformat.size", "character", "character.cursor.ibeam",
        "list.bullet", "list.number", "checklist", "tablecells", "curlybraces", "curlybraces.square",
        "chevron.left.forwardslash.chevron.right", "doc.text", "doc.on.doc", "doc.plaintext",
        "note.text", "book", "books.vertical", "graduationcap", "lightbulb", "brain",
        "bubble.left", "bubble.left.and.bubble.right", "quote.bubble", "captions.bubble",
        "questionmark.circle", "exclamationmark.bubble", "info.circle", "checkmark.circle",
        "arrow.triangle.2.circlepath", "arrow.up.left.and.arrow.down.right", "arrow.down.right.and.arrow.up.left",
        "wand.and.rays", "scissors", "highlighter", "paintbrush", "slider.horizontal.3",
        "globe", "character.book.closed", "function", "sum", "percent",
        "flame", "sun.max", "bolt", "star", "heart", "tag", "bookmark", "flag",
        "gearshape", "hammer", "wrench.and.screwdriver", "terminal", "keyboard",
        "envelope", "paperplane", "megaphone", "briefcase", "person", "face.smiling",
        "calendar", "clock", "magnifyingglass", "eye", "lock", "key", "link",
    ]
}


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
        .frame(width: Metrics.settingsWidth, height: Metrics.settingsHeight)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var copilot: CopilotService
    @State private var accessibilityTrusted = AccessibilityService.isTrusted

    /// Remembers whether the BYOK section is expanded via the persisted
    /// `modelSource` flag, so it stays open for people who use a custom model.
    private var byokExpanded: Binding<Bool> {
        Binding(
            get: { store.settings.modelSource == .byok },
            set: { store.settings.modelSource = $0 ? .byok : .copilot }
        )
    }

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
            Section("Copilot CLI") {
                HStack {
                    TextField("Copilot CLI path", text: $store.settings.copilotPath)
                    Button("Browse…") { pickFile(into: \.copilotPath) }
                }
            }
            Section("Models") {
                Picker("Default model", selection: $store.settings.model) {
                    ForEach(copilot.availableModels) { m in Text(m.name).tag(m.id) }
                }
                Button("Refresh models") { copilot.refreshModels() }
                    .controlSize(.small)

                DisclosureGroup(isExpanded: byokExpanded) {
                    BYOKConfig(store: store, copilot: copilot)
                } label: {
                    Label("Bring Your Own Model", systemImage: "key.horizontal")
                }
            }
            Section("Behavior") {
                Toggle("Launch at login", isOn: $store.settings.launchAtLogin)
                Toggle("Show popup automatically on selection", isOn: $store.settings.showPopupAutomatically)
                Stepper("Clipboard history: \(store.settings.maxHistoryItems) items",
                        value: $store.settings.maxHistoryItems, in: 5...500, step: 5)
                Stepper("Default result choices: \(store.settings.defaultChoices)",
                        value: $store.settings.defaultChoices, in: 1...5)
                Stepper("AI run timeout: \(store.settings.runTimeoutSeconds)s",
                        value: $store.settings.runTimeoutSeconds, in: 15...600, step: 15)
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

/// Manages the list of bring-your-own models: add/remove plus a detail editor
/// for the selected entry.
private struct BYOKConfig: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var copilot: CopilotService
    @State private var selection: BYOKModel.ID?

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return store.settings.byokModels.firstIndex { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.settings.byokModels.isEmpty {
                Text("No custom models yet. Add one to use your own provider (OpenAI, Azure, Anthropic, Ollama, …).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 2) {
                    ForEach(store.settings.byokModels) { m in row(for: m) }
                }
            }

            HStack {
                Button { addModel() } label: { Label("Add Model", systemImage: "plus") }
                    .controlSize(.small)
                Button(role: .destructive) { removeSelected() } label: { Label("Remove", systemImage: "trash") }
                    .controlSize(.small)
                    .disabled(selection == nil)
            }

            if let idx = selectedIndex {
                Divider()
                BYOKModelEditor(model: $store.settings.byokModels[idx], copilot: copilot)
                    .id(store.settings.byokModels[idx].id)
            }
        }
    }

    private func row(for m: BYOKModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: m.isConfigured ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(m.isConfigured ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(m.displayName.isEmpty ? "Untitled model" : m.displayName)
                Text(m.type.label).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selection == m.id ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selection = m.id }
    }

    private func addModel() {
        let m = BYOKModel()
        store.settings.byokModels.append(m)
        selection = m.id
    }

    private func removeSelected() {
        guard let id = selection else { return }
        store.settings.byokModels.removeAll { $0.id == id }
        selection = nil
    }
}

/// Detail editor for a single BYOK model, including a per-model connection test.
private struct BYOKModelEditor: View {
    @Binding var model: BYOKModel
    @ObservedObject var copilot: CopilotService
    @State private var pinging = false
    @State private var pingResult: PingResult?

    private enum PingResult { case ok, failure(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Display name (optional)", text: $model.name)

            Picker("Provider", selection: $model.type) {
                ForEach(BYOKProviderType.allCases) { t in Text(t.label).tag(t) }
            }
            .onChange(of: model.type) { _, newValue in applyProviderDefaults(for: newValue) }

            TextField("Model / deployment name", text: $model.model)
                .help(modelHelp)

            TextField(model.type.baseURLPlaceholder, text: $model.baseURL)
                .help(model.type.baseURLHelp)

            if model.type.requiresAPIKey {
                SecureField("API key", text: $model.apiKey)
                    .help("Sent as the provider API key.")
            }
            if model.type.allowsBearerToken {
                SecureField("Bearer token (optional)", text: $model.bearerToken)
                    .help("Takes precedence over the API key. Used by providers that require Authorization: Bearer.")
            }
            if model.type.supportsWireAPI {
                Picker("Wire API", selection: $model.wireAPI) {
                    ForEach(WireAPI.allCases) { w in Text(w.label).tag(w) }
                }
                .help("Chat Completions for broad compatibility; Responses for reasoning/tool models (e.g. GPT-5 series).")
            }
            if model.type.isAzure {
                TextField("Azure API version", text: $model.azureAPIVersion)
                    .help("e.g. 2024-10-21")
            }

            HStack(spacing: 8) {
                Button {
                    pingProvider()
                } label: {
                    if pinging {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(model.type.isLocal ? "Testing (loading model)…" : "Testing…")
                        }
                    } else {
                        Label("Test Connection", systemImage: "bolt.horizontal.circle")
                    }
                }
                .controlSize(.small)
                .disabled(pinging || !model.isConfigured)

                switch pingResult {
                case .ok:
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                case .failure(let msg):
                    Label(msg, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red).font(.caption)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                case nil:
                    EmptyView()
                }
            }

            Text(model.type.isLocal
                 ? "Local provider — runs on your device with no GitHub Copilot authentication."
                 : "Credentials are stored in Pop Sidekick's settings file. BYOK uses static keys only and bypasses GitHub Copilot authentication.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: model.id) { _, _ in pingResult = nil }
    }

    private var modelHelp: String {
        model.type.isAzure
            ? "Required. Your Azure deployment name."
            : "Required. The exact model id your provider expects, e.g. gpt-4o, claude-3-5-sonnet, or phi-4-mini."
    }

    /// Prefills the base URL with the provider's default when the field is empty
    /// or still holds another provider's default.
    private func applyProviderDefaults(for provider: BYOKProviderType) {
        let current = model.baseURL.trimmingCharacters(in: .whitespaces)
        let knownDefaults = Set(BYOKProviderType.allCases.map(\.defaultBaseURL)).subtracting([""])
        if current.isEmpty || knownDefaults.contains(current) {
            model.baseURL = provider.defaultBaseURL
        }
    }

    private func pingProvider() {
        pinging = true
        pingResult = nil
        copilot.ping(model: model) { result in
            pinging = false
            switch result {
            case .success: pingResult = .ok
            case .failure(let error): pingResult = .failure(error.localizedDescription)
            }
        }
    }
}

private struct TasksSettings: View {
    @ObservedObject var store: SettingsStore
    @State private var selection: TaskDef.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tasks")
                .font(.headline)
            Text("Tasks run on the selected text. Toggle the popup column to show a task as a button in the popup, and assign an optional shortcut to run it on the current selection from anywhere.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("").frame(width: 30)
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Popup").frame(width: 52)
                Text("Shortcut").frame(width: 110, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)

            List(selection: $selection) {
                ForEach($store.settings.tasks) { $task in
                    HStack(spacing: 8) {
                        IconPickerButton(icon: $task.icon)
                        TextField("Name", text: $task.name)
                            .textFieldStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Toggle("", isOn: $task.showInPopup)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .frame(width: 52)
                        HotkeyRecorder(hotkey: $task.hotkey)
                            .frame(width: 110, alignment: .leading)
                    }
                    .tag(task.id)
                }
                .onDelete { store.settings.tasks.remove(atOffsets: $0) }
                .onMove { store.settings.tasks.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(height: 170)

            if let id = selection,
               let idx = store.settings.tasks.firstIndex(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Instruction for “\(store.settings.tasks[idx].name)”")
                        .font(.caption.weight(.semibold))
                    TextEditor(text: $store.settings.tasks[idx].instruction)
                        .font(.system(size: 12))
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                }
            } else {
                Text("Select a task to edit its instruction.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(height: 70, alignment: .top)
            }

            HStack {
                Button {
                    let task = TaskDef(name: "New Task", icon: "wand.and.stars",
                                       instruction: "Describe what to do with the text.")
                    store.settings.tasks.append(task)
                    selection = task.id
                } label: { Label("Add Task", systemImage: "plus") }
                Button(role: .destructive) {
                    if let id = selection {
                        store.settings.tasks.removeAll { $0.id == id }
                        selection = nil
                    }
                } label: { Label("Remove", systemImage: "trash") }
                .disabled(selection == nil)
                Spacer()
                Button("Restore Defaults") {
                    store.settings.tasks = TaskDef.builtins
                    selection = nil
                }
            }
        }
        .padding()
    }
}

/// A button that records a single global keyboard shortcut for a task.
private struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if recording { stop() } else { start() }
            } label: {
                Text(recording ? "Press keys…" : (hotkey?.display ?? "Set"))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .frame(minWidth: 58)
                    .foregroundStyle(recording ? Color.accentColor : .primary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if hotkey != nil && !recording {
                Button {
                    hotkey = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Escape cancels recording.
            if event.keyCode == 53 {
                stop()
                return nil
            }
            let carbon = HotkeyRecorder.carbonModifiers(event.modifierFlags)
            // Require at least one modifier so shortcuts don't collide with typing.
            guard carbon != 0 else { return nil }
            hotkey = Hotkey(keyCode: UInt32(event.keyCode), modifiers: carbon)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: Int = 0
        if flags.contains(.command) { m |= Hotkey.cmdKeyMask }
        if flags.contains(.shift) { m |= Hotkey.shiftKeyMask }
        if flags.contains(.option) { m |= Hotkey.optionKeyMask }
        if flags.contains(.control) { m |= Hotkey.controlKeyMask }
        return UInt32(m)
    }
}

private struct AdvancedSettings: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Security") {
                Toggle("Automatically approve tool requests", isOn: $store.settings.autoApproveTools)
                Text("When on, Copilot may run tools, MCP servers, and skills without asking. Turn off to reject all tool use (AI tasks still work for plain text transforms).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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


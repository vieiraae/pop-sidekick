import SwiftUI

/// The expanded editor: text, task/tone/format/length pickers, extra
/// instructions, model picker, choices slider, run/cancel, and results.
struct EditView: View {
    @ObservedObject var vm: PopupViewModel
    @ObservedObject var copilot = CopilotService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let clip = vm.editingClip {
                clipEditor(clip)
            } else {
                editor
                resultsSection
            }
        }
        .padding(12)
        .frame(width: Metrics.editWidth)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text("Pop Sidekick")
                .font(.headline)
            Spacer()
            SearchMenu(engines: vm.searchEngines, defaultEngine: vm.defaultSearchEngine) { engine in
                vm.searchWeb(vm.editText, engine: engine)
            }
            IconButton(systemName: vm.pinned ? "pin.fill" : "pin",
                       help: vm.pinned ? "Unpin" : "Pin — keep window on top",
                       prominent: vm.pinned) {
                vm.pinned.toggle()
                PopupController.shared?.setPinned(vm.pinned)
            }
            IconButton(systemName: "gearshape", help: "Settings") {
                SettingsWindow.show()
            }
            IconButton(systemName: "xmark", help: "Close") { vm.forceClose() }
        }
    }

    // MARK: - Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Line 1: editable text, or an image preview when an image clip was
            // sent to the editor (it's attached as base64 on Run).
            if let data = vm.attachedImageData, let image = NSImage(data: data) {
                imagePreview(image)
            } else {
                TextEditor(text: $vm.editText)
                    .font(.system(size: 12))
                    .frame(height: 70)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
            }

            // Line 2: task / tone / format / length (compact icon menus)
            HStack(spacing: 0) {
                compactMenu(title: "Task", categoryIcon: "wand.and.stars",
                            selection: $vm.taskID,
                            currentIcon: vm.taskID.flatMap { id in vm.allTasks.first { $0.id == id }?.icon },
                            currentLabel: vm.taskID.flatMap { id in vm.allTasks.first { $0.id == id }?.name },
                            options: vm.allTasks.map { ($0.id, $0.name, $0.icon) })
                Spacer(minLength: 8)
                compactMenu(title: "Tone", categoryIcon: "speaker.wave.2",
                            selection: $vm.tone,
                            currentIcon: vm.tone?.icon,
                            currentLabel: vm.tone?.rawValue,
                            options: Tone.allCases.map { ($0, $0.rawValue, $0.icon) })
                Spacer(minLength: 8)
                compactMenu(title: "Format", categoryIcon: "text.alignleft",
                            selection: $vm.format,
                            currentIcon: vm.format?.icon,
                            currentLabel: vm.format?.rawValue,
                            options: OutputFormat.allCases.map { ($0, $0.rawValue, $0.icon) })
                Spacer(minLength: 8)
                compactMenu(title: "Length", categoryIcon: "ruler",
                            selection: $vm.length,
                            currentIcon: vm.length?.icon,
                            currentLabel: vm.length?.rawValue,
                            options: Length.allCases.map { ($0, $0.rawValue, $0.icon) })
            }

            // Line 3: extra instructions
            TextField("Additional instructions…", text: $vm.extraInstructions)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !vm.isProcessing { vm.runEdit() } }

            // Line 4: model / choices / run
            HStack(spacing: 8) {
                Text("Model")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Picker("", selection: $vm.model) {
                    ForEach(copilot.availableModels) { m in Text(m.name).tag(m.id) }
                }
                .frame(maxWidth: 160)
                .help("Model")
                .tooltip("Model")

                modelTuningMenu

                HStack(spacing: 4) {
                    Image(systemName: "number")
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(vm.choices) },
                        set: { vm.choices = Int($0.rounded()) }
                    ), in: 1...5, step: 1)
                    .frame(width: 90)
                    Text("\(vm.choices)")
                        .font(.caption.monospacedDigit())
                        .frame(width: 14)
                }
                .help("Number of result choices")
                .tooltip("Number of result choices")

                Spacer()

                if vm.isProcessing {
                    Button(role: .cancel) { vm.cancel() } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("Cancel")
                    .tooltip("Cancel")
                } else {
                    Button { vm.runEdit() } label: {
                        Image(systemName: "play.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Run (⌘↩)")
                    .tooltip("Run (⌘↩)")
                }
            }
        }
    }

    /// Auto routing tier when the model is Auto, otherwise reasoning effort for
    /// models that support it. Hidden for anything else (e.g. BYOK).
    @ViewBuilder
    private var modelTuningMenu: some View {
        if vm.model == "auto" {
            Menu {
                Picker("Auto routing", selection: $vm.autoTier) {
                    ForEach([""] + AutoTierOption.all, id: \.self) { t in
                        Label(AutoTierOption.label(t), systemImage: AutoTierOption.icon(t)).tag(t)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: AutoTierOption.icon(vm.autoTier))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Auto routing: \(AutoTierOption.label(vm.autoTier))")
            .tooltip("Auto routing: \(AutoTierOption.label(vm.autoTier))")
        } else if let opt = copilot.models.first(where: { $0.id == vm.model }), !opt.efforts.isEmpty {
            let current = ReasoningLevel.resolve(vm.reasoningEffort, supported: opt.efforts) ?? ""
            let defaultLabel = opt.defaultEffort.map { "Model default (\(ReasoningLevel.label($0)))" } ?? "Model default"
            Menu {
                Picker("Reasoning effort", selection: $vm.reasoningEffort) {
                    Label(defaultLabel, systemImage: ReasoningLevel.icon("")).tag("")
                    ForEach(opt.efforts, id: \.self) { e in
                        Label(ReasoningLevel.label(e), systemImage: ReasoningLevel.icon(e)).tag(e)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: ReasoningLevel.icon(current))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Reasoning effort: \(ReasoningLevel.label(current))")
            .tooltip("Reasoning effort: \(ReasoningLevel.label(current))")
        }
    }

    @ViewBuilder
    private func imagePreview(_ image: NSImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
            IconButton(systemName: "xmark.circle.fill", help: "Remove image") {
                vm.attachedImageData = nil
            }
            .padding(2)
        }
        .help("This image is attached to the request when you Run.")
    }

    @ViewBuilder
    private func compactMenu<T: Hashable>(
        title: String,
        categoryIcon: String,
        selection: Binding<T?>,
        currentIcon: String?,
        currentLabel: String?,
        options: [(T, String, String)]
    ) -> some View {
        let isSet = selection.wrappedValue != nil
        HStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Menu {
                Picker(selection: selection) {
                    Label("None", systemImage: "slash.circle").tag(Optional<T>.none)
                    ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                        Label(opt.1, systemImage: opt.2).tag(Optional(opt.0))
                    }
                } label: { EmptyView() }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: currentIcon ?? "slash.circle")
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .opacity(0.5)
                }
                .frame(height: 28)
                .padding(.horizontal, 8)
                .foregroundStyle(isSet ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.secondary))
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .help("\(title): \(currentLabel ?? "None")")
        .tooltip("\(title): \(currentLabel ?? "None")")
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        if let status = vm.statusMessage, vm.results.allSatisfy({ $0.text.isEmpty }) {
            HStack(spacing: 6) {
                if vm.isProcessing { ProgressView().controlSize(.small) }
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        let allEmpty = vm.results.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !vm.results.isEmpty && !vm.isProcessing && allEmpty && vm.statusMessage == nil {
            HStack(spacing: 6) {
                Image(systemName: "text.badge.xmark").foregroundStyle(.secondary)
                Text("No result").font(.caption).foregroundStyle(.secondary)
            }
        } else if !vm.results.isEmpty {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(vm.results.enumerated()), id: \.element.id) { idx, item in
                        ResultRowView(vm: vm, item: item, index: idx)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }

    // MARK: - Clip editing

    private func clipEditor(_ clip: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Edit clipboard item")
                .font(.subheadline.weight(.semibold))
            TextEditor(text: $vm.editingClipText)
                .font(.system(size: 12))
                .frame(height: 120)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            HStack {
                Spacer()
                Button("Cancel") { vm.cancelEditingClip() }
                Button("Save") { vm.saveEditingClip() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

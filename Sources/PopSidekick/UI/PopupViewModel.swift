import SwiftUI
import AppKit

struct ResultItem: Identifiable {
    let id = UUID()
    var choice: Int
    var text: String
    var isStreaming: Bool
}

enum PopupMode {
    case compact
    case edit
}

/// Drives a single popup instance: holds the selected text, edit configuration,
/// AI results, and orchestrates Copilot SDK runs through `CopilotService`.
@MainActor
final class PopupViewModel: ObservableObject {
    @Published var mode: PopupMode = .compact
    @Published var pinned = false
    @Published var isProcessing = false
    @Published var statusMessage: String?
    @Published var results: [ResultItem] = []

    @Published var selectedText: String = ""
    /// Whether the source selection accepts edits. When false, write-back
    /// actions (Cut/Paste and AI replace) are hidden in the compact bar.
    @Published var isEditable: Bool = true

    // Edit configuration
    @Published var editText: String = ""
    @Published var taskID: String? { didSet { SettingsStore.shared.settings.editTaskID = taskID } }
    @Published var tone: Tone? { didSet { SettingsStore.shared.settings.editTone = tone } }
    @Published var format: OutputFormat? { didSet { SettingsStore.shared.settings.editFormat = format } }
    @Published var length: Length? { didSet { SettingsStore.shared.settings.editLength = length } }
    @Published var extraInstructions: String = ""
    @Published var model: String = "auto"
    @Published var choices: Int = 1

    // Inline clip editing (history/bookmark items)
    @Published var editingClip: ClipItem?
    @Published var editingClipText: String = ""

    /// Called when the popup wants to close itself.
    var onRequestClose: (() -> Void)?

    /// The app that was frontmost when the popup appeared. Clipboard keystrokes
    /// are re-targeted at it so they don't land in our own popup.
    var sourceApp: NSRunningApplication?

    private var currentRun: RunHandle?
    private let copilot = CopilotService.shared
    /// When true, the (single) result is written back over the source selection
    /// once the run finishes. Used by the compact-bar quick actions.
    private var replaceOnComplete = false

    var allTasks: [TaskDef] { SettingsStore.shared.settings.allTasks }

    func configure(with text: String, isEditable: Bool = true) {
        selectedText = text
        editText = text
        self.isEditable = isEditable
        let settings = SettingsStore.shared.settings
        model = settings.model
        choices = max(1, settings.defaultChoices)
        // Restore persisted Edit-panel selections (nil = unset).
        taskID = settings.editTaskID
        tone = settings.editTone
        format = settings.editFormat
        length = settings.editLength
        results = []
        statusMessage = nil
    }

    // MARK: - Clipboard actions

    /// Re-activates the source app, runs a keystroke action, then closes.
    private func performClipboard(_ action: @escaping () -> Void) {
        sourceApp?.activate()
        let willClose = !pinned
        if willClose { onRequestClose?() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
            action()
        }
    }

    func doCut() { performClipboard { AccessibilityService.cut() } }

    func doCopy() { performClipboard { AccessibilityService.copy() } }

    func doPaste() { performClipboard { AccessibilityService.paste() } }

    func paste(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        performClipboard { AccessibilityService.paste() }
    }

    func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - AI actions

    func runBuiltin(_ id: String) {
        guard let task = allTasks.first(where: { $0.id == id }) else { return }
        run(task: task)
    }

    func run(task: TaskDef) {
        let prompt = buildPrompt(instruction: task.instruction, text: selectedText, includeStyling: false)
        startRun(prompt: prompt, replace: isEditable, statusLabel: "\(task.name)…")
    }

    func runEdit() {
        let task = taskID.flatMap { id in allTasks.first(where: { $0.id == id }) }
        let prompt = buildPrompt(instruction: task?.instruction, text: editText, includeStyling: true)
        startRun(prompt: prompt, statusLabel: task.map { "\($0.name)…" } ?? "Working…")
    }

    private func buildPrompt(instruction: String?, text: String, includeStyling: Bool) -> String {
        var parts: [String] = []
        if let instruction, !instruction.isEmpty {
            parts.append(instruction)
        }
        if includeStyling {
            if let tone {
                parts.append("Write in a \(tone.rawValue.lowercased()) tone.")
            }
            if let format {
                parts.append(format.instruction)
            }
            if let length {
                parts.append(length.instruction)
            }
            let extra = extraInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if !extra.isEmpty {
                parts.append("Additional instructions: \(extra)")
            }
        }
        parts.append("Reply with only the resulting text.")
        parts.append("\nText:\n\(text)")
        return parts.joined(separator: "\n")
    }

    private func startRun(prompt: String, replace: Bool = false, statusLabel: String = "Working…") {
        currentRun.map { copilot.cancel($0) }
        replaceOnComplete = replace
        // Replace mode always produces a single result to write back.
        let n = replace ? 1 : max(1, min(10, choices))
        results = (0..<n).map { ResultItem(choice: $0, text: "", isStreaming: true) }
        isProcessing = true
        statusMessage = statusLabel
        // Quick replace actions stay in the compact bar (just the animated
        // border + a cancel button); only explicit Edit runs expand the editor.
        if !replace && mode == .compact { mode = .edit }

        let handle = copilot.run(prompt: prompt, model: model, choices: n)
        currentRun = handle

        handle.onDelta = { [weak self] choice, piece in
            guard let self else { return }
            if let idx = self.results.firstIndex(where: { $0.choice == choice }) {
                self.results[idx].text += piece
            }
        }
        handle.onResult = { [weak self] choice, text in
            guard let self else { return }
            if let idx = self.results.firstIndex(where: { $0.choice == choice }) {
                self.results[idx].text = text
                self.results[idx].isStreaming = false
            }
        }
        handle.onError = { [weak self] message in
            guard let self else { return }
            self.replaceOnComplete = false
            self.isProcessing = false
            self.statusMessage = message
            self.currentRun = nil
            for i in self.results.indices { self.results[i].isStreaming = false }
        }
        handle.onDone = { [weak self] in
            guard let self else { return }
            self.isProcessing = false
            self.statusMessage = nil
            self.currentRun = nil
            for i in self.results.indices { self.results[i].isStreaming = false }
            if self.replaceOnComplete {
                self.replaceOnComplete = false
                let result = self.results.first?.text ?? ""
                if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.paste(result)
                }
            }
        }
    }

    func cancel() {
        if let run = currentRun {
            copilot.cancel(run)
            currentRun = nil
        }
        replaceOnComplete = false
        isProcessing = false
        statusMessage = "Cancelled"
        for i in results.indices { results[i].isStreaming = false }
    }

    // MARK: - Result actions

    func refine(_ text: String) {
        editText = text
        mode = .edit
    }

    // MARK: - Clip editing

    func beginEditingClip(_ item: ClipItem) {
        editingClip = item
        editingClipText = item.text
        mode = .edit
    }

    func saveEditingClip() {
        if let item = editingClip {
            ClipboardStore.shared.edit(item, newText: editingClipText)
        }
        editingClip = nil
    }

    func cancelEditingClip() {
        editingClip = nil
    }

    // MARK: - Mode / window

    func expandToEdit() {
        mode = .edit
        if copilot.models.count <= 1 { copilot.refreshModels() }
    }

    func close() {
        if pinned { return }
        onRequestClose?()
    }

    func forceClose() {
        if let run = currentRun { copilot.cancel(run) }
        onRequestClose?()
    }
}

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
    case prompt
    case history
}

/// Which tab the clipboard window shows.
enum ClipboardTab {
    case history
    case bookmarks
}

/// Drives a single popup instance: holds the selected text, edit configuration,
/// AI results, and orchestrates Copilot SDK runs through `CopilotService`.
@MainActor
final class PopupViewModel: ObservableObject {
    @Published var mode: PopupMode = .compact
    @Published var clipboardTab: ClipboardTab = .history
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
    /// Free-form instruction entered in the prompt panel.
    @Published var promptText: String = ""
    @Published var model: String = "auto"
    @Published var choices: Int = 1

    // Inline clip editing (history/bookmark items)
    @Published var editingClip: ClipItem?
    @Published var editingClipText: String = ""

    /// When an image clip is sent to the editor, its PNG data is held here so a
    /// preview shows in the input area and the image is attached (base64) on Run.
    @Published var attachedImageData: Data?

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
    /// Tasks the user has chosen to surface as buttons in the compact bar.
    var popupTasks: [TaskDef] { SettingsStore.shared.settings.popupTasks }

    /// A folder when the selection is a path to an existing directory, so the
    /// popup can offer to reveal it in Finder. Computed once per selection.
    @Published private(set) var detectedFolder: URL?
    /// A URL when the selection is (essentially) a single hyperlink, so the
    /// popup can offer to open it in the default browser. Computed once.
    @Published private(set) var detectedURL: URL?

    /// Returns a URL if the trimmed text is a path to an existing directory.
    private static func folderURL(in text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Accept file:// URLs and strip surrounding quotes.
        if trimmed.hasPrefix("file://"), let u = URL(string: trimmed) { trimmed = u.path }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
           (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")), trimmed.count >= 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        // Only treat absolute or home-relative paths as folder candidates.
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: expanded)
    }

    /// A URL when the selection is (essentially) a single hyperlink, so the
    /// popup can offer to open it in the default browser.
    /// Returns a URL if the trimmed text is a single link (http/https/mailto or
    /// a bare domain). Returns nil for prose that merely contains a URL.
    private static func firstURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0 == " " || $0 == "\n" }) else { return nil }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = detector.firstMatch(in: trimmed, options: [], range: range),
              match.range == range,
              let url = match.url else { return nil }
        return url
    }

    func configure(with text: String, isEditable: Bool = true) {
        selectedText = text
        editText = text
        self.isEditable = isEditable
        attachedImageData = nil
        detectedFolder = Self.folderURL(in: text)
        detectedURL = Self.firstURL(in: text)
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

    /// The richest representation currently on the system clipboard, used to
    /// tailor the Paste button's options to what will actually be pasted.
    var currentClipboardContent: RichContent? { RichContent.read(from: .general) }

    /// Pastes whatever is currently on the system clipboard, honoring the style.
    func pasteCurrentClipboard(style: PasteStyle = .source) {
        switch style {
        case .source:
            performClipboard { AccessibilityService.paste() }
        case .matchStyle:
            performClipboard { AccessibilityService.pasteAndMatchStyle() }
        case .plainText:
            let pb = NSPasteboard.general
            let plain = pb.string(forType: .string) ?? ""
            pb.clearContents()
            pb.setString(plain, forType: .string)
            performClipboard { AccessibilityService.paste() }
        }
    }

    /// Writes rich content to the pasteboard and pastes it with the given style.
    private func performPaste(_ content: RichContent, style: PasteStyle) {
        content.write(to: NSPasteboard.general, style: style)
        sourceApp?.activate()
        let willClose = !pinned
        if willClose { onRequestClose?() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
            switch style {
            case .matchStyle: AccessibilityService.pasteAndMatchStyle()
            default: AccessibilityService.paste()
            }
        }
    }

    /// Pastes clipboard-history / bookmark content, preserving styling/images.
    func paste(_ content: RichContent, style: PasteStyle = .source) {
        performPaste(content, style: style)
    }

    /// Pastes plain or Markdown text. Source style renders Markdown to rich text.
    func paste(_ text: String, style: PasteStyle = .source) {
        let content = (style == .source) ? RichContent.fromMarkdown(text) : RichContent(plainText: text)
        performPaste(content, style: style)
    }

    func copyToClipboard(_ text: String) {
        RichContent.fromMarkdown(text).write(to: NSPasteboard.general, style: .source)
    }

    /// Copies clipboard-history / bookmark content to the system clipboard
    /// without pasting. Used in read-only contexts where Paste isn't available.
    func copy(_ content: RichContent, style: PasteStyle = .source) {
        content.write(to: NSPasteboard.general, style: style)
        if !pinned { onRequestClose?() }
    }

    /// Opens the detected URL in the default browser, then closes (unless pinned).
    func openDetectedURL() {
        guard let url = detectedURL else { return }
        NSWorkspace.shared.open(url)
        if !pinned { onRequestClose?() }
    }

    /// Opens the detected folder in Finder, then closes (unless pinned).
    func openDetectedFolder() {
        guard let url = detectedFolder else { return }
        NSWorkspace.shared.open(url)
        if !pinned { onRequestClose?() }
    }

    /// Configurable search engines and the default one (used by the search
    /// button; the rest are offered in its dropdown).
    var searchEngines: [SearchEngine] { SettingsStore.shared.settings.searchEngines }
    var defaultSearchEngine: SearchEngine? { SettingsStore.shared.settings.defaultSearchEngine }

    /// Searches the web for the given text with the chosen engine (or the
    /// configured default), opening the result in the default browser. Closes
    /// afterward unless pinned. Falls back to the current selection when no
    /// text is given.
    func searchWeb(_ text: String? = nil, engine: SearchEngine? = nil) {
        let query = (text ?? selectedText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let chosen = engine ?? defaultSearchEngine
        guard let url = chosen?.url(for: query) else { return }
        NSWorkspace.shared.open(url)
        if !pinned { onRequestClose?() }
    }

    // MARK: - AI actions

    func run(task: TaskDef) {
        let prompt = buildPrompt(instruction: task.instruction, text: selectedText, includeStyling: false)
        startRun(prompt: prompt, replace: isEditable, statusLabel: "\(task.name)…")
    }

    /// Handles a task button/menu selection from the compact bar. For editable
    /// selections it runs the task inline (replacing the text). For read-only
    /// selections it opens the editor with the task preselected and runs it
    /// automatically, producing a result the user can copy/paste.
    func activateTask(_ task: TaskDef) {
        if isEditable {
            run(task: task)
        } else {
            taskID = task.id
            expandToEdit()
            runEdit()
        }
    }

    /// Extracts the text from an image clipboard item using Copilot (OCR) and
    /// pastes the result into the source app. The image is sent as a blob
    /// attachment to a vision-capable model.
    func extractTextFromImage(_ item: ClipItem) {
        guard let png = item.imageData else { return }
        extractText(fromImagePNG: png)
    }

    /// Extracts text from the image currently on the system clipboard.
    func extractTextFromCurrentClipboard() {
        guard let png = currentClipboardContent?.imageData else { return }
        extractText(fromImagePNG: png)
    }

    private func extractText(fromImagePNG png: Data) {
        let attachment: [String: Any] = [
            "type": "blob",
            "data": png.base64EncodedString(),
            "mimeType": "image/png",
            "displayName": "clipboard-image.png",
        ]
        let prompt = """
        Extract all text from the attached image exactly as it appears, \
        preserving line breaks and reading order. Reply with only the extracted \
        text and nothing else. If the image contains no text, reply with nothing.
        """
        startRun(prompt: prompt, replace: true, statusLabel: "Extracting text…",
                 attachments: [attachment])
    }

    func runEdit() {
        let task = taskID.flatMap { id in allTasks.first(where: { $0.id == id }) }
        let hasImage = attachedImageData != nil
        let prompt = buildPrompt(instruction: task?.instruction, text: editText,
                                 includeStyling: true, hasImage: hasImage)
        var attachments: [[String: Any]]? = nil
        if let png = attachedImageData {
            attachments = [[
                "type": "blob",
                "data": png.base64EncodedString(),
                "mimeType": "image/png",
                "displayName": "clipboard-image.png",
            ]]
        }
        startRun(prompt: prompt, statusLabel: task.map { "\($0.name)…" } ?? "Working…",
                 attachments: attachments)
    }

    /// Runs the free-form prompt. For editable selections it mirrors quick-task
    /// behaviour — shows the compact processing bar and replaces the selection.
    /// For read-only selections it opens the editor with the prompt placed in the
    /// additional-instructions field and runs it automatically, so the result
    /// lands in the editor where it can be copied/pasted.
    func runPrompt() {
        let instruction = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        if isEditable {
            let prompt = buildPrompt(instruction: instruction, text: selectedText, includeStyling: false)
            mode = .compact
            startRun(prompt: prompt, replace: true, statusLabel: instruction)
        } else {
            taskID = nil
            extraInstructions = instruction
            expandToEdit()
            runEdit()
        }
    }

    private func buildPrompt(instruction: String?, text: String, includeStyling: Bool,
                             hasImage: Bool = false) -> String {
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
        if !text.isEmpty {
            parts.append("\nText:\n\(text)")
        } else if hasImage {
            parts.append("\nThe content to work with is in the attached image.")
        }
        return parts.joined(separator: "\n")
    }

    private func startRun(prompt: String, replace: Bool = false, statusLabel: String = "Working…",
                          attachments: [[String: Any]]? = nil) {
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

        let handle = copilot.run(prompt: prompt, model: model, choices: n, attachments: attachments)
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

    /// Mode to return to after finishing an inline clip edit (so editing an item
    /// from the history popup returns to the history list, not the compact bar).
    private var clipEditReturnMode: PopupMode = .compact

    func beginEditingClip(_ item: ClipItem) {
        clipEditReturnMode = (mode == .history) ? .history : .compact
        editingClip = item
        editingClipText = item.text
        mode = .edit
    }

    /// Opens the AI editor populated with a clipboard item's content. Rich text
    /// is reduced to plain text; an image is shown as a preview and attached as
    /// base64 when the run starts.
    func editClipWithAI(_ item: ClipItem) {
        editingClip = nil
        results = []
        statusMessage = nil
        if item.isImage {
            attachedImageData = item.imageData
            editText = ""
            selectedText = ""
        } else {
            attachedImageData = nil
            editText = item.text
            selectedText = item.text
        }
        // Mirror the popup Edit window's current values.
        let settings = SettingsStore.shared.settings
        model = settings.model
        choices = max(1, settings.defaultChoices)
        taskID = settings.editTaskID
        tone = settings.editTone
        format = settings.editFormat
        length = settings.editLength
        mode = .edit
        if copilot.models.count <= 1 { copilot.refreshModels() }
    }

    func saveEditingClip() {
        if let item = editingClip {
            ClipboardStore.shared.edit(item, newText: editingClipText)
        }
        editingClip = nil
        if clipEditReturnMode == .history { mode = .history }
    }

    func cancelEditingClip() {
        editingClip = nil
        if clipEditReturnMode == .history { mode = .history }
    }

    // MARK: - Mode / window

    /// Switches the current popup into the clipboard-history browser (used by
    /// the compact bar's history button). Preserves the source app and
    /// editability so paste still targets the original selection.
    func openHistory() {
        results = []
        statusMessage = nil
        clipboardTab = .history
        mode = .history
    }

    /// Opens the clipboard window focused on the Bookmarks tab.
    func openBookmarks() {
        results = []
        statusMessage = nil
        clipboardTab = .bookmarks
        mode = .history
    }

    /// Configures the popup as a standalone clipboard-history browser, launched
    /// from the global hotkey. Paste targets the previously focused app.
    func configureForHistory() {
        selectedText = ""
        editText = ""
        isEditable = true
        results = []
        statusMessage = nil
        mode = .history
    }

    func expandToEdit() {
        mode = .edit
        if copilot.models.count <= 1 { copilot.refreshModels() }
    }

    /// Replaces the popup with a free-form prompt panel.
    func openPrompt() {
        promptText = ""
        results = []
        statusMessage = nil
        mode = .prompt
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

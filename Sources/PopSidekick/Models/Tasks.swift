import Foundation

/// A recorded global keyboard shortcut (Carbon key code + modifier mask).
struct Hotkey: Codable, Hashable {
    /// Virtual key code (e.g. `kVK_ANSI_P`).
    var keyCode: UInt32
    /// Carbon modifier flags (cmdKey | shiftKey | optionKey | controlKey).
    var modifiers: UInt32

    /// Human-readable representation, e.g. "⌘⇧P".
    var display: String {
        var s = ""
        if modifiers & UInt32(Hotkey.controlKeyMask) != 0 { s += "⌃" }
        if modifiers & UInt32(Hotkey.optionKeyMask) != 0 { s += "⌥" }
        if modifiers & UInt32(Hotkey.shiftKeyMask) != 0 { s += "⇧" }
        if modifiers & UInt32(Hotkey.cmdKeyMask) != 0 { s += "⌘" }
        s += Hotkey.keyName(for: keyCode)
        return s
    }

    // Carbon modifier masks (avoid importing Carbon everywhere).
    static let cmdKeyMask: Int = 1 << 8
    static let shiftKeyMask: Int = 1 << 9
    static let optionKeyMask: Int = 1 << 11
    static let controlKeyMask: Int = 1 << 12

    /// Maps common virtual key codes to display characters.
    static func keyName(for code: UInt32) -> String {
        if let s = keyMap[code] { return s }
        return "?"
    }

    private static let keyMap: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
        28: "8", 25: "9",
        49: "Space", 36: "↩", 48: "⇥", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",",
        47: ".", 44: "/", 50: "`", 42: "\\",
    ]
}

/// A unit of AI work the user can run on selected text.
struct TaskDef: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    /// SF Symbol name.
    var icon: String
    /// Instruction sent to the model. The selected text is appended separately.
    var instruction: String
    /// Built-in tasks ship with the app by default. Users may still edit or
    /// delete them; this flag only marks their origin.
    var isBuiltin: Bool
    /// When true the task is offered as a dedicated icon button in the popup's
    /// compact action bar (in addition to always appearing in the Tasks menu).
    var showInPopup: Bool
    /// Optional global shortcut that runs the task on the current selection.
    var hotkey: Hotkey?

    init(id: String = UUID().uuidString,
         name: String,
         icon: String,
         instruction: String,
         isBuiltin: Bool = false,
         showInPopup: Bool = false,
         hotkey: Hotkey? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.instruction = instruction
        self.isBuiltin = isBuiltin
        self.showInPopup = showInPopup
        self.hotkey = hotkey
    }

    enum CodingKeys: String, CodingKey {
        case id, name, icon, instruction, isBuiltin, showInPopup, hotkey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decode(String.self, forKey: .icon)
        instruction = try c.decode(String.self, forKey: .instruction)
        isBuiltin = (try? c.decodeIfPresent(Bool.self, forKey: .isBuiltin)) ?? false ?? false
        showInPopup = (try? c.decodeIfPresent(Bool.self, forKey: .showInPopup)) ?? false ?? false
        hotkey = (try? c.decodeIfPresent(Hotkey.self, forKey: .hotkey)) ?? nil
    }
}

extension TaskDef {
    /// The default task set seeded on first launch. Users can edit, reorder via
    /// add/delete, or remove any of these afterwards.
    static let builtins: [TaskDef] = [
        TaskDef(id: "proofread", name: "Proofread", icon: "checkmark.seal",
                instruction: "Proofread the text. Fix spelling, grammar, and punctuation while preserving the original meaning and tone.",
                isBuiltin: true, showInPopup: true),
        TaskDef(id: "rewrite", name: "Rewrite", icon: "pencil.and.outline",
                instruction: "Rewrite the text to improve clarity and flow while keeping the original meaning.",
                isBuiltin: true, showInPopup: true),
        TaskDef(id: "synonyms", name: "Use synonyms", icon: "arrow.triangle.2.circlepath",
                instruction: "Rewrite the text replacing words with suitable synonyms, keeping the same meaning and tone.",
                isBuiltin: true),
        TaskDef(id: "minor_revise", name: "Minor revise", icon: "slider.horizontal.below.rectangle",
                instruction: "Make light revisions to the text, correcting issues and lightly polishing wording without changing structure.",
                isBuiltin: true),
        TaskDef(id: "major_revise", name: "Major revise", icon: "wand.and.stars",
                instruction: "Substantially revise and improve the text, restructuring sentences for maximum clarity and impact.",
                isBuiltin: true),
        TaskDef(id: "describe", name: "Describe", icon: "text.magnifyingglass",
                instruction: "Describe what the text is about in clear, concise language.",
                isBuiltin: true),
        TaskDef(id: "answer", name: "Answer", icon: "bubble.left.and.bubble.right",
                instruction: "Treat the text as a question or request and provide a direct, helpful answer.",
                isBuiltin: true),
        TaskDef(id: "explain", name: "Explain", icon: "lightbulb",
                instruction: "Explain the text clearly so that a general audience can understand it.",
                isBuiltin: true),
        TaskDef(id: "expand", name: "Expand", icon: "arrow.up.left.and.arrow.down.right",
                instruction: "Expand the text with additional detail, examples, and context while staying on topic.",
                isBuiltin: true),
        TaskDef(id: "summarize", name: "Summarize", icon: "text.append",
                instruction: "Summarize the text concisely, capturing the key points.",
                isBuiltin: true),
    ]
}

enum Tone: String, CaseIterable, Codable, Identifiable {
    case professional = "Professional"
    case casual = "Casual"
    case enthusiastic = "Enthusiastic"
    case informational = "Informational"
    case confident = "Confident"
    case technical = "Technical"
    case funny = "Funny"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .professional: return "briefcase"
        case .casual: return "sun.max"
        case .enthusiastic: return "flame"
        case .informational: return "info.circle"
        case .confident: return "checkmark.seal"
        case .technical: return "gearshape"
        case .funny: return "face.smiling"
        }
    }
}

enum OutputFormat: String, CaseIterable, Codable, Identifiable {
    case singleParagraph = "Single paragraph"
    case paragraphs = "Paragraphs with line breaks"
    case list = "List"
    case orderedList = "Ordered list"
    case table = "Table"
    case taskList = "Task list"
    case headings = "Headings"
    case blockquotes = "Blockquotes"
    case codeBlocks = "Code blocks"
    case emojis = "Emojis"
    case html = "HTML"
    case json = "JSON"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .singleParagraph: return "text.alignleft"
        case .paragraphs: return "text.justify"
        case .list: return "list.bullet"
        case .orderedList: return "list.number"
        case .table: return "tablecells"
        case .taskList: return "checklist"
        case .headings: return "textformat.size"
        case .blockquotes: return "text.quote"
        case .codeBlocks: return "curlybraces"
        case .emojis: return "face.smiling"
        case .html: return "chevron.left.forwardslash.chevron.right"
        case .json: return "curlybraces.square"
        }
    }

    var instruction: String {
        switch self {
        case .singleParagraph: return "Format the output as a single paragraph."
        case .paragraphs: return "Format the output as multiple paragraphs separated by line breaks."
        case .list: return "Format the output as a bulleted list."
        case .orderedList: return "Format the output as a numbered (ordered) list."
        case .table: return "Format the output as a Markdown table."
        case .taskList: return "Format the output as a Markdown task list using - [ ] items."
        case .headings: return "Organize the output using Markdown headings."
        case .blockquotes: return "Format the output as Markdown blockquotes."
        case .codeBlocks: return "Format the output inside fenced code blocks."
        case .emojis: return "Include relevant emojis throughout the output."
        case .html: return "Format the output as valid HTML markup."
        case .json: return "Format the output as valid JSON."
        }
    }
}

enum Length: String, CaseIterable, Codable, Identifiable {
    case headline = "Headline"
    case minimal = "Minimal"
    case tight = "Tight"
    case normal = "Normal"
    case verbose = "Verbose"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .headline: return "textformat.size.larger"
        case .minimal: return "minus"
        case .tight: return "arrow.down.right.and.arrow.up.left"
        case .normal: return "equal"
        case .verbose: return "arrow.up.left.and.arrow.down.right"
        }
    }

    var instruction: String {
        switch self {
        case .headline: return "Keep the output extremely short — a single headline-length phrase."
        case .minimal: return "Keep the output minimal — one or two short sentences."
        case .tight: return "Keep the output tight and concise."
        case .normal: return "Use a normal, balanced length."
        case .verbose: return "Be thorough and verbose, elaborating where helpful."
        }
    }
}

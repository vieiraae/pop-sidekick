import Foundation

/// An item captured from the clipboard.
struct ClipItem: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var text: String
    var date: Date = Date()
    var bookmarked: Bool = false

    var preview: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let oneLine = trimmed.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 80 ? String(oneLine.prefix(80)) + "…" : oneLine
    }
}

/// Stores clipboard history and bookmarks, persisted to disk.
@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published private(set) var history: [ClipItem] = []
    @Published private(set) var bookmarks: [ClipItem] = []

    private let historyURL: URL
    private let bookmarksURL: URL

    private init() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PopSidekick", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        historyURL = dir.appendingPathComponent("history.json")
        bookmarksURL = dir.appendingPathComponent("bookmarks.json")
        load()
    }

    private func load() {
        if let data = try? Data(contentsOf: historyURL),
           let items = try? JSONDecoder().decode([ClipItem].self, from: data) {
            history = items
        }
        if let data = try? Data(contentsOf: bookmarksURL),
           let items = try? JSONDecoder().decode([ClipItem].self, from: data) {
            bookmarks = items
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: historyURL, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(bookmarks) {
            try? data.write(to: bookmarksURL, options: .atomic)
        }
    }

    /// Records newly copied text, de-duplicating and capping to the configured max.
    func record(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = history.firstIndex(where: { $0.text == text }) {
            let existing = history.remove(at: idx)
            history.insert(existing, at: 0)
        } else {
            history.insert(ClipItem(text: text), at: 0)
        }
        let max = SettingsStore.shared.settings.maxHistoryItems
        if history.count > max {
            history = Array(history.prefix(max))
        }
        persist()
    }

    func delete(_ item: ClipItem) {
        history.removeAll { $0.id == item.id }
        bookmarks.removeAll { $0.id == item.id }
        persist()
    }

    func bookmark(_ item: ClipItem) {
        guard !bookmarks.contains(where: { $0.text == item.text }) else { return }
        var copy = item
        copy.bookmarked = true
        bookmarks.insert(copy, at: 0)
        if let idx = history.firstIndex(where: { $0.id == item.id }) {
            history[idx].bookmarked = true
        }
        persist()
    }

    func unbookmark(_ item: ClipItem) {
        bookmarks.removeAll { $0.text == item.text }
        if let idx = history.firstIndex(where: { $0.text == item.text }) {
            history[idx].bookmarked = false
        }
        persist()
    }

    func edit(_ item: ClipItem, newText: String) {
        if let idx = history.firstIndex(where: { $0.id == item.id }) {
            history[idx].text = newText
        }
        if let idx = bookmarks.firstIndex(where: { $0.id == item.id }) {
            bookmarks[idx].text = newText
        }
        persist()
    }

    func clearHistory() {
        history.removeAll { !$0.bookmarked }
        persist()
    }
}

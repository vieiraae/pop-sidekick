import Foundation

/// An item captured from the clipboard.
struct ClipItem: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var text: String
    var date: Date = Date()
    var bookmarked: Bool = false
    // Optional rich representations (nil for legacy/plain items).
    var rtfData: Data? = nil
    var html: String? = nil
    /// Filename of the image within the store's images directory. The bytes
    /// themselves live on disk (see `imageData`) so history.json stays small.
    var imageFile: String? = nil
    /// In-memory image bytes (PNG). Not persisted inline — hydrated from
    /// `imageFile` on load and written out on record.
    var imageData: Data? = nil
    /// File reference paths, when the item is one or more copied files.
    var filePaths: [String]? = nil
    /// A web/mailto link, when the item is primarily a single URL.
    var linkURL: String? = nil

    /// Persist everything except the raw image bytes; images are stored as
    /// separate files referenced by `imageFile`.
    enum CodingKeys: String, CodingKey {
        case id, text, date, bookmarked, rtfData, html, imageFile, filePaths, linkURL
    }

    var content: RichContent {
        RichContent(plainText: text, rtfData: rtfData, html: html, imageData: imageData,
                    fileURLs: filePaths?.map { URL(fileURLWithPath: $0) },
                    url: linkURL.flatMap { URL(string: $0) })
    }

    var kind: ClipKind { content.kind }
    var isImage: Bool { kind == .image }
    var isFile: Bool { kind == .file }
    var isLink: Bool { kind == .link }
    /// Whether the item's text can be edited inline (plain/rich text only).
    var isEditableText: Bool { kind == .text || kind == .richText }
    var hasRichText: Bool { rtfData != nil || html != nil }

    init(content: RichContent) {
        self.text = content.plainText
        self.rtfData = content.rtfData
        self.html = content.html
        self.imageData = content.imageData
        self.filePaths = content.fileURLs?.map { $0.path }
        self.linkURL = content.url?.absoluteString
    }

    init(text: String) {
        self.text = text
    }

    var preview: String { content.preview }
}

/// Stores clipboard history and bookmarks, persisted to disk.
@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published private(set) var history: [ClipItem] = []
    @Published private(set) var bookmarks: [ClipItem] = []

    /// Images larger than this are not captured into history (keeps the store
    /// from ballooning with full-resolution screenshots / pasted artwork).
    private let maxImageBytes = 5 * 1024 * 1024

    private let historyURL: URL
    private let bookmarksURL: URL
    private let imagesDir: URL
    private var persistWorkItem: DispatchWorkItem?

    private init() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PopSidekick", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        historyURL = dir.appendingPathComponent("history.json")
        bookmarksURL = dir.appendingPathComponent("bookmarks.json")
        imagesDir = dir.appendingPathComponent("images", isDirectory: true)
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        history = loadItems(from: historyURL)
        bookmarks = loadItems(from: bookmarksURL)
    }

    /// Decodes a clip array, hydrating external image bytes. A file that exists
    /// but fails to decode is backed up rather than silently discarded.
    private func loadItems(from url: URL) -> [ClipItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            var items = try JSONDecoder().decode([ClipItem].self, from: data)
            for i in items.indices {
                if let name = items[i].imageFile {
                    items[i].imageData = try? Data(contentsOf: imagesDir.appendingPathComponent(name))
                }
            }
            return items
        } catch {
            let backup = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            Diag.log("ClipboardStore: failed to decode \(url.lastPathComponent): \(error); backed up to \(backup.lastPathComponent)")
            return []
        }
    }

    /// Persists both stores, debounced so a burst of clipboard changes doesn't
    /// rewrite the JSON files on every keystroke.
    private func persist() {
        persistWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.persistNow() }
        }
        persistWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func persistNow() {
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: historyURL, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(bookmarks) {
            try? data.write(to: bookmarksURL, options: .atomic)
        }
        collectOrphanImages()
    }

    /// Writes an image to the images directory keyed by a stable content hash,
    /// returning the filename to reference from a clip item.
    private func storeImage(_ data: Data) -> String {
        let name = "\(RichContent.sha256(data)).png"
        let url = imagesDir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
        }
        return name
    }

    /// Deletes image files no longer referenced by any history/bookmark item.
    private func collectOrphanImages() {
        let referenced = Set((history + bookmarks).compactMap { $0.imageFile })
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: imagesDir, includingPropertiesForKeys: nil) else { return }
        for file in files where !referenced.contains(file.lastPathComponent) {
            try? fm.removeItem(at: file)
        }
    }

    /// Records newly copied content, de-duplicating and capping to the max.
    func record(_ content: RichContent) {
        guard !content.isEmpty else { return }
        // Skip oversized images so the store doesn't grow without bound.
        if let bytes = content.imageData, bytes.count > maxImageBytes { return }

        var item = ClipItem(content: content)
        if let bytes = item.imageData {
            item.imageFile = storeImage(bytes)
        }
        let key = content.dedupeKey
        if let idx = history.firstIndex(where: { $0.content.dedupeKey == key }) {
            let existing = history.remove(at: idx)
            history.insert(existing, at: 0)
        } else {
            history.insert(item, at: 0)
        }
        let max = SettingsStore.shared.settings.maxHistoryItems
        if history.count > max {
            // Never evict bookmarked items when trimming.
            history = Array(history.prefix(max))
        }
        persist()
    }

    /// Convenience for recording plain text.
    func record(_ text: String) {
        record(RichContent(plainText: text))
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

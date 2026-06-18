import SwiftUI

/// The Popup-style compact action bar shown immediately on selection.
struct CompactBarView: View {
    @ObservedObject var vm: PopupViewModel
    @ObservedObject var clipboard = ClipboardStore.shared
    /// Natural size of the action bar, captured so the processing state can
    /// keep the exact same footprint (no popup resize when the run starts).
    @State private var barSize: CGSize = .zero

    var body: some View {
        Group {
            if vm.isProcessing {
                processingBar
            } else {
                actionBar
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: BarSizeKey.self, value: proxy.size)
                        }
                    )
            }
        }
        .onPreferenceChange(BarSizeKey.self) { barSize = $0 }
        .arrowCursor()
    }

    private var processingBar: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(vm.statusMessage ?? "Working…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            IconButton(systemName: "stop.fill", help: "Cancel") { vm.cancel() }
        }
        .padding(.horizontal, 8)
        .frame(width: barSize.width > 0 ? barSize.width : nil,
               height: barSize.height > 0 ? barSize.height : nil)
        .frame(minWidth: Metrics.processingMinWidth)
    }

    private var actionBar: some View {
        HStack(spacing: 2) {
            if vm.detectedFolder != nil {
                IconButton(systemName: "folder", help: "Open in Finder", prominent: true) {
                    vm.openDetectedFolder()
                }
                VBar()
            }
            if vm.detectedURL != nil {
                IconButton(systemName: "arrow.up.right.square", help: "Open Link", prominent: true) {
                    vm.openDetectedURL()
                }
                VBar()
            }
            if vm.isEditable {
                IconButton(systemName: "scissors", help: "Cut") { vm.doCut() }
            }
            IconButton(systemName: "doc.on.doc", help: "Copy") { vm.doCopy() }
            if vm.isEditable {
                PasteMenu(systemName: "clipboard", help: "Paste") { style in
                    vm.pasteCurrentClipboard(style: style)
                }
            }

            VBar()

            historyMenu
            bookmarksMenu

            if vm.isEditable {
                VBar()

                ForEach(vm.popupTasks) { task in
                    IconButton(systemName: task.icon, help: task.name) { vm.run(task: task) }
                }
                tasksMenu
            }

            VBar()

            IconButton(systemName: "text.bubble", help: "Ask Copilot — describe how to transform the text") {
                vm.openPrompt()
            }
            IconButton(systemName: "sparkles", help: "Edit", prominent: true) {
                vm.expandToEdit()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .fixedSize()
    }

    private var historyMenu: some View {
        Menu {
            if clipboard.history.isEmpty {
                Text("No clipboard history").foregroundStyle(.secondary)
            } else {
                ForEach(clipboard.history) { item in
                    Menu {
                        Button("Paste") { vm.paste(item.content, style: .source) }
                        if item.isImage {
                            Button("Paste Extracted Text") { vm.extractTextFromImage(item) }
                        }
                        if item.hasRichText {
                            Button("Paste and Match Style") { vm.paste(item.content, style: .matchStyle) }
                        }
                        if !item.isImage {
                            Button(item.isFile ? "Paste Path as Text" : "Paste as Plain Text") {
                                vm.paste(item.content, style: .plainText)
                            }
                        }
                        Divider()
                        Button(item.bookmarked ? "Bookmarked" : "Bookmark") {
                            clipboard.bookmark(item)
                        }.disabled(item.bookmarked)
                        if item.isEditableText {
                            Button("Edit…") { vm.beginEditingClip(item) }
                        }
                        Button("Delete", role: .destructive) { clipboard.delete(item) }
                    } label: {
                        clipItemLabel(item)
                    } primaryAction: {
                        vm.paste(item.content, style: .source)
                    }
                }
                Divider()
                Button("Clear History") { clipboard.clearHistory() }
            }
        } label: {
            MenuIconLabel(systemName: "clock.arrow.circlepath", accessibilityLabel: "Clipboard History")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Clipboard History")
        .tooltip("Clipboard History")
    }

    private var bookmarksMenu: some View {
        Menu {
            if clipboard.bookmarks.isEmpty {
                Text("No bookmarks").foregroundStyle(.secondary)
            } else {
                ForEach(clipboard.bookmarks) { item in
                    Menu {
                        Button("Paste") { vm.paste(item.content, style: .source) }
                        if item.isImage {
                            Button("Paste Extracted Text") { vm.extractTextFromImage(item) }
                        }
                        if item.hasRichText {
                            Button("Paste and Match Style") { vm.paste(item.content, style: .matchStyle) }
                        }
                        if !item.isImage {
                            Button(item.isFile ? "Paste Path as Text" : "Paste as Plain Text") {
                                vm.paste(item.content, style: .plainText)
                            }
                        }
                        Divider()
                        Button("Unbookmark") { clipboard.unbookmark(item) }
                        if item.isEditableText {
                            Button("Edit…") { vm.beginEditingClip(item) }
                        }
                        Button("Delete", role: .destructive) { clipboard.delete(item) }
                    } label: {
                        clipItemLabel(item)
                    } primaryAction: {
                        vm.paste(item.content, style: .source)
                    }
                }
            }
        } label: {
            MenuIconLabel(systemName: "bookmark", accessibilityLabel: "Bookmarks")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Bookmarks")
        .tooltip("Bookmarks")
    }

    /// Menu label for a clip item — a type-appropriate icon plus a preview.
    @ViewBuilder
    private func clipItemLabel(_ item: ClipItem) -> some View {
        switch item.kind {
        case .image:
            Label {
                Text("Image")
            } icon: {
                if let image = item.content.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "photo")
                }
            }
        case .file:
            Label {
                Text(item.preview)
            } icon: {
                if let path = item.filePaths?.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "doc")
                }
            }
        case .link:
            Label(item.preview, systemImage: "link")
        case .richText:
            Label(item.preview, systemImage: "textformat")
        case .text:
            Label(item.preview, systemImage: "text.alignleft")
        }
    }

    private var tasksMenu: some View {
        Menu {
            ForEach(vm.allTasks) { task in
                Button {
                    vm.run(task: task)
                } label: {
                    Label(task.name, systemImage: task.icon)
                }
            }
        } label: {
            MenuIconLabel(systemName: "chevron.up.chevron.down", accessibilityLabel: "Tasks")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Tasks")
        .tooltip("Tasks")
    }
}

/// Captures the action bar's natural size so the processing state can reuse it.
private struct BarSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

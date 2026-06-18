import SwiftUI

/// The PopClip-style compact action bar shown immediately on selection.
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
    }

    private var actionBar: some View {
        HStack(spacing: 2) {
            if vm.isEditable {
                IconButton(systemName: "scissors", help: "Cut") { vm.doCut() }
            }
            IconButton(systemName: "doc.on.doc", help: "Copy") { vm.doCopy() }
            if vm.isEditable {
                IconButton(systemName: "clipboard", help: "Paste") { vm.doPaste() }
            }

            VBar()

            historyMenu
            bookmarksMenu

            if vm.isEditable {
                VBar()

                IconButton(systemName: "checkmark.seal", help: "Proofread") { vm.runBuiltin("proofread") }
                IconButton(systemName: "pencil.and.outline", help: "Rewrite") { vm.runBuiltin("rewrite") }
                tasksMenu
            }

            VBar()

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
                        Button("Paste") { vm.paste(item.text) }
                        Button(item.bookmarked ? "Bookmarked" : "Bookmark") {
                            clipboard.bookmark(item)
                        }.disabled(item.bookmarked)
                        Button("Edit…") { vm.beginEditingClip(item) }
                    } label: {
                        Text(item.preview)
                    } primaryAction: {
                        vm.paste(item.text)
                    }
                }
                Divider()
                Button("Clear History") { clipboard.clearHistory() }
            }
        } label: {
            MenuIconLabel(systemName: "clock.arrow.circlepath")
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
                    Menu(item.preview) {
                        Button("Paste") { vm.paste(item.text) }
                        Button("Unbookmark") { clipboard.unbookmark(item) }
                        Button("Edit…") { vm.beginEditingClip(item) }
                    }
                }
            }
        } label: {
            MenuIconLabel(systemName: "bookmark")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Bookmarks")
        .tooltip("Bookmarks")
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
            MenuIconLabel(systemName: "list.bullet.rectangle")
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

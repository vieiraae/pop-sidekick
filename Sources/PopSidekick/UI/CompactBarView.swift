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
                PasteMenu(systemName: "clipboard", help: "Paste",
                          kind: vm.currentClipboardContent?.kind,
                          onPaste: { style in vm.pasteCurrentClipboard(style: style) },
                          onExtractText: { vm.extractTextFromCurrentClipboard() })
            }

            VBar()

            IconButton(systemName: "clock.arrow.circlepath", help: "Clipboard History") {
                vm.openHistory()
            }
            IconButton(systemName: "bookmark", help: "Bookmarks") {
                vm.openBookmarks()
            }
            SearchMenu(engines: vm.searchEngines, defaultEngine: vm.defaultSearchEngine) { engine in
                vm.searchWeb(engine: engine)
            }

            VBar()

            ForEach(vm.popupTasks) { task in
                IconButton(systemName: task.icon, help: task.name) { vm.activateTask(task) }
            }
            tasksMenu

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

    private var tasksMenu: some View {
        Menu {
            ForEach(vm.allTasks) { task in
                Button {
                    vm.activateTask(task)
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

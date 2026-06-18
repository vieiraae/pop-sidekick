import SwiftUI

/// A minimal "Ask Copilot" prompt bar shown in place of the compact action
/// bar: a single text field plus a send button. Enter (or ⌘↩) sends, Esc
/// dismisses. Running, cancelling and replacing the selection are handled by
/// the shared processing bar — identical to a quick task.
struct PromptView: View {
    @ObservedObject var vm: PopupViewModel
    @FocusState private var promptFocused: Bool

    private var isEmpty: Bool {
        vm.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.bubble")
                .foregroundStyle(.tint)

            TextField("Ask Copilot to transform the text…", text: $vm.promptText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($promptFocused)
                .onSubmit { vm.runPrompt() }

            Button { vm.runPrompt() } label: {
                Image(systemName: "play.fill")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isEmpty)
            .help("Send (⌘↩)")
            .tooltip("Send (⌘↩)")

            // Esc dismisses the prompt bar.
            Button { vm.mode = .compact } label: { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: Metrics.promptWidth)
        .onAppear { promptFocused = true }
        .arrowCursor()
    }
}

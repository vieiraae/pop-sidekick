import SwiftUI

/// A single AI result with refine / copy / paste actions.
struct ResultRowView: View {
    @ObservedObject var vm: PopupViewModel
    let item: ResultItem
    let index: Int

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if vm.results.count > 1 {
                    Text("Choice \(index + 1)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if item.isStreaming {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                IconButton(systemName: "arrow.uturn.left", help: "Refine — send to the editor") {
                    vm.refine(item.text)
                }
                IconButton(systemName: copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                    vm.copyToClipboard(item.text)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
                }
                IconButton(systemName: "clipboard", help: "Paste") {
                    vm.paste(item.text)
                }
            }
            Text(item.text.isEmpty ? " " : item.text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

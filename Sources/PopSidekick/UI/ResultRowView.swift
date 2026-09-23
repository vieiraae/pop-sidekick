import SwiftUI
import AppKit

/// A single AI result with diff review, follow-ups, and refine / copy / paste.
struct ResultRowView: View {
    @ObservedObject var vm: PopupViewModel
    let item: ResultItem
    let index: Int

    @State private var copied = false
    @State private var showFollowUp = false
    @State private var followUpText = ""
    @FocusState private var followUpFocused: Bool

    private static let quickFollowUps: [(String, String)] = [
        ("Shorter", "arrow.down.right.and.arrow.up.left"),
        ("Longer", "arrow.up.left.and.arrow.down.right"),
        ("Simpler", "text.badge.minus"),
        ("More formal", "briefcase"),
        ("More casual", "cup.and.saucer"),
        ("Fix grammar and spelling", "textformat.abc.dottedunderline"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if item.diffVisible, let diff = item.diff, !item.isStreaming {
                Text(diffText(diff))
                    .font(.system(size: 12))
                    .tint(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { url in
                        if url.scheme == "sidekick-diff", let i = Int(url.host ?? "") {
                            vm.toggleChange(item.id, i)
                        }
                        return .handled
                    })
                diffFooter(diff)
            } else {
                Text(renderedText)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showFollowUp { followUpField }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var header: some View {
        HStack(spacing: 2) {
            if vm.results.count > 1 {
                Text("Choice \(index + 1)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if !item.versions.isEmpty {
                Text("v\(item.versions.count + 1)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(item.instructions.last.map { "Follow-up: \($0)" } ?? "")
            }
            if item.isStreaming {
                ProgressView().controlSize(.mini).padding(.leading, 4)
            }
            Spacer()
            if !item.versions.isEmpty && !item.isStreaming {
                IconButton(systemName: "arrow.uturn.backward.circle", help: "Back to previous version") {
                    vm.revertVersion(item.id)
                }
            }
            if let diff = item.diff, diff.changeCount > 0, !item.isStreaming {
                IconButton(systemName: "plus.forwardslash.minus",
                           help: item.diffVisible ? "Hide changes" : "Show changes",
                           prominent: item.diffVisible) {
                    vm.toggleDiff(item.id)
                }
            }
            IconButton(systemName: "bubble.left.and.text.bubble.right",
                       help: "Follow up — revise this result", prominent: showFollowUp) {
                showFollowUp.toggle()
                if showFollowUp { DispatchQueue.main.async { followUpFocused = true } }
            }
            .disabled(item.isStreaming)
            IconButton(systemName: "arrow.uturn.left", help: "Refine — send to the editor") {
                vm.refine(item.effectiveText)
            }
            IconButton(systemName: copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                vm.copyToClipboard(item.effectiveText)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
            }
            if vm.isEditable {
                IconButton(systemName: "clipboard", help: "Paste (⌥ pastes plain text)") {
                    let plain = NSEvent.modifierFlags.contains(.option)
                    vm.paste(item.effectiveText, style: plain ? .plainText : .source)
                }
            }
        }
    }

    private func diffFooter(_ diff: TextDiff) -> some View {
        let accepted = diff.changeCount - item.rejected.count
        return HStack(spacing: 6) {
            Text("\(accepted) of \(diff.changeCount) changes · click a change to toggle it")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Accept all") { vm.setAllChanges(item.id, accepted: true) }
                .disabled(item.rejected.isEmpty)
            Button("Reject all") { vm.setAllChanges(item.id, accepted: false) }
                .disabled(accepted == 0)
        }
        .buttonStyle(.link)
        .font(.caption2)
    }

    private var followUpField: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(Self.quickFollowUps, id: \.0) { title, icon in
                    Button { send(title) } label: { Label(title, systemImage: icon) }
                }
            } label: {
                Image(systemName: "wand.and.stars")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Quick follow-ups")
            TextField("Follow up… (e.g. make it friendlier)", text: $followUpText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($followUpFocused)
                .onSubmit { send(followUpText) }
            IconButton(systemName: "arrow.up.circle.fill", help: "Send follow-up", prominent: true) {
                send(followUpText)
            }
            .disabled(followUpText.trimmingCharacters(in: .whitespaces).isEmpty || item.isStreaming)
        }
    }

    private func send(_ instruction: String) {
        guard !item.isStreaming else { return }
        vm.followUp(item.id, instruction: instruction)
        followUpText = ""
    }

    /// The diff as one flowing text: each change is a link that toggles it.
    private func diffText(_ diff: TextDiff) -> AttributedString {
        var out = AttributedString()
        for segment in diff.segments {
            switch segment {
            case .same(let t):
                out += AttributedString(t)
            case let .change(i, removed, inserted):
                let rejected = item.rejected.contains(i)
                let link = URL(string: "sidekick-diff://\(i)")
                if !removed.isEmpty {
                    var r = AttributedString(removed)
                    r.link = link
                    if rejected {
                        r.backgroundColor = Color.yellow.opacity(0.22)
                    } else {
                        r.backgroundColor = Color.red.opacity(0.16)
                        r.strikethroughStyle = Text.LineStyle(pattern: .solid, color: .red.opacity(0.8))
                    }
                    out += r
                }
                if !inserted.isEmpty {
                    var a = AttributedString(inserted)
                    a.link = link
                    if rejected {
                        a.backgroundColor = Color.primary.opacity(0.06)
                        a.strikethroughStyle = Text.LineStyle(pattern: .solid, color: .secondary)
                    } else {
                        a.backgroundColor = Color.green.opacity(0.24)
                    }
                    out += a
                }
            }
        }
        return out
    }

    /// The result rendered as Markdown (inline styling), falling back to plain.
    private var renderedText: AttributedString {
        let text = item.effectiveText
        if text.isEmpty { return AttributedString(" ") }
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return AttributedString(text)
    }
}

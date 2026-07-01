import SwiftUI

/// Minimalist icon-only button with a tooltip.
struct IconButton: View {
    let systemName: String
    let help: String
    var prominent: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 28)
                .foregroundStyle(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.10) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .tooltip(help)
        .accessibilityLabel(Text(help))
        .onHover { hovering = $0 }
    }
}

/// A thin vertical divider between groups of icons.
struct VBar: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 2)
    }
}

/// Icon label for `Menu`-based buttons so they get the same hover treatment
/// as `IconButton` (a rounded highlight on hover).
struct MenuIconLabel: View {
    let systemName: String
    var prominent: Bool = false
    var accessibilityLabel: String = ""
    @State private var hovering = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 30, height: 28)
            .foregroundStyle(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
            .accessibilityLabel(Text(accessibilityLabel))
            .onHover { hovering = $0 }
    }
}

/// A split search button: clicking the icon searches with the default engine;
/// the chevron opens a menu listing all configured engines.
struct SearchMenu: View {
    var engines: [SearchEngine]
    var defaultEngine: SearchEngine?
    var onSearch: (SearchEngine) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            IconButton(systemName: "magnifyingglass", help: searchHelp) {
                if let engine = defaultEngine ?? engines.first { onSearch(engine) }
            }
            if engines.count > 1 {
                Menu {
                    ForEach(engines) { engine in
                        Button { onSearch(engine) } label: {
                            Label(engine.name, systemImage: "magnifyingglass")
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 28)
                        .foregroundStyle(.secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(hovering ? Color.primary.opacity(0.10) : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onHover { hovering = $0 }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Search with…")
                .tooltip("Search with…")
            }
        }
    }

    private var searchHelp: String {
        if let name = (defaultEngine ?? engines.first)?.name { return "Search with \(name)" }
        return "Search the web"
    }
}

/// A split paste button: clicking the icon pastes with source styling; the
/// small chevron opens a menu offering Match Style and Plain Text.
/// The Paste split-button. Its dropdown adapts to what's on the clipboard:
/// plain text/link/file paste with no dropdown; rich text exposes the style
/// options; an image pastes the image and offers "Paste Extracted Text".
struct PasteMenu: View {
    var systemName: String = "clipboard"
    var help: String = "Paste"
    /// Kind of the content currently on the clipboard (nil → treat as plain).
    var kind: ClipKind?
    var onPaste: (PasteStyle) -> Void
    var onExtractText: () -> Void = {}

    @State private var hovering = false

    private var showsDropdown: Bool { kind == .richText || kind == .image }

    var body: some View {
        HStack(spacing: 0) {
            IconButton(systemName: systemName, help: help) { onPaste(.source) }
            if showsDropdown {
                Menu {
                    if kind == .image {
                        Button { onPaste(.source) } label: { Label("Paste Image", systemImage: "photo") }
                        Button { onExtractText() } label: { Label("Paste Extracted Text", systemImage: "text.viewfinder") }
                    } else {
                        Button { onPaste(.source) } label: { Label("Paste", systemImage: "clipboard") }
                        Button { onPaste(.matchStyle) } label: { Label("Paste and Match Style", systemImage: "textformat") }
                        Button { onPaste(.plainText) } label: { Label("Paste as Plain Text", systemImage: "textformat.abc.dottedunderline") }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 28)
                        .foregroundStyle(.secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(hovering ? Color.primary.opacity(0.10) : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onHover { hovering = $0 }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Paste options")
                .tooltip("Paste options")
            }
        }
    }
}

import SwiftUI

/// Minimalist icon-only button with a tooltip, matching the PopClip aesthetic.
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
    @State private var hovering = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 30, height: 28)
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

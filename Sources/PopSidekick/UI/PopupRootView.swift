import SwiftUI

/// Root popup content. Switches between the compact bar and the expanded
/// editor, wraps everything in a translucent material with the animated
/// "Copilot working" border.
struct PopupRootView: View {
    @ObservedObject var vm: PopupViewModel

    var body: some View {
        ZStack {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
                .overlay(
                    AnimatedBorder(active: vm.isProcessing, cornerRadius: cornerRadius)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
        }
        .padding(Metrics.popupInset)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: vm.mode)
    }

    private var cornerRadius: CGFloat { vm.mode == .edit ? Metrics.editCornerRadius : Metrics.compactCornerRadius }

    @ViewBuilder
    private var content: some View {
        switch vm.mode {
        case .compact:
            CompactBarView(vm: vm)
        case .edit:
            EditView(vm: vm)
        case .prompt:
            PromptView(vm: vm)
        }
    }
}

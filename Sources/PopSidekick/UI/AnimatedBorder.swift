import SwiftUI

/// A subtle, colorful animated gradient stroke used to indicate the Copilot
/// SDK is actively working. Rotates a conic gradient around the popup border.
struct AnimatedBorder: View {
    var active: Bool
    var cornerRadius: CGFloat = 16
    var lineWidth: CGFloat = 2.5

    @State private var angle: Double = 0

    private let colors: [Color] = [
        .pink, .purple, .blue, .cyan, .green, .yellow, .orange, .pink
    ]

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                AngularGradient(
                    gradient: Gradient(colors: colors),
                    center: .center,
                    angle: .degrees(angle)
                ),
                lineWidth: lineWidth
            )
            .opacity(active ? 1 : 0)
            .animation(.easeInOut(duration: 0.4), value: active)
            .onChange(of: active) { _, isActive in
                if isActive { spin() }
            }
            .onAppear { if active { spin() } }
            .allowsHitTesting(false)
    }

    private func spin() {
        angle = 0
        withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
            angle = 360
        }
    }
}

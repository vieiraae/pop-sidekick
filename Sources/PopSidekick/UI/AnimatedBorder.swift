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

/// Subtle colorful palette shared by the "working" indicators.
private let workingColors: [Color] = [
    .pink, .purple, .blue, .cyan, .teal, .green, .yellow, .orange, .pink,
]


/// An SF Symbol that gently cycles through the working palette while `active`.
struct AnimatedIcon: View {
    let systemName: String
    var active: Bool

    var body: some View {
        if active {
            Image(systemName: systemName)
                .hidden()
                .overlay(
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        LinearGradient(
                            gradient: Gradient(colors: workingColors),
                            startPoint: .leading, endPoint: .trailing
                        )
                        .hueRotation(.degrees((t * 80).truncatingRemainder(dividingBy: 360)))
                        .mask(Image(systemName: systemName))
                    }
                )
                .transition(.opacity)
        } else {
            Image(systemName: systemName)
        }
    }
}

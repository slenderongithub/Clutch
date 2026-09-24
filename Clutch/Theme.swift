import SwiftUI

/// Clutch's visual identity, built only from the system accent + semantic
/// system colors (RULES.md: no hex), so it follows the user's accent choice
/// and Dark Mode automatically.
enum BrandGradient {
    static let fill = LinearGradient(
        colors: [.accentColor, .purple],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Soft top-down glow behind page headers; fades fully to clear so it
    /// never ends in a visible edge.
    static let wash = LinearGradient(
        colors: [.accentColor.opacity(0.16), .purple.opacity(0.06), .clear],
        startPoint: .top,
        endPoint: .bottom
    )
}

extension View {
    /// Frosted rounded card with a hairline edge — the app's one card style.
    func glassCard(cornerRadius: CGFloat = 12) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
    }
}

let appSpring = Animation.spring(response: 0.4, dampingFraction: 0.8)

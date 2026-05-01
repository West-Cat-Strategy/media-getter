import SwiftUI

extension Color {
    static let studioBackground = Color(red: 0.08, green: 0.09, blue: 0.11)
    static let studioSurface = Color(red: 0.14, green: 0.15, blue: 0.18)
    static let studioSurfaceLight = Color(red: 0.20, green: 0.21, blue: 0.24)
    static let studioBorder = Color.white.opacity(0.1)
    static let studioBorderHover = Color.white.opacity(0.2)
    static let studioAccentHover = Color.accentColor.opacity(0.8)
}

extension Animation {
    static let studioSpring = Animation.spring(response: 0.3, dampingFraction: 0.7)
    static let studioFast = Animation.easeInOut(duration: 0.15)
}

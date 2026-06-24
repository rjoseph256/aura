import SwiftUI

enum AuraTheme {
    // Aura brand — aurora on near-black
    static let bg      = Color(red: 0.031, green: 0.035, blue: 0.059) // #08090F
    static let surface = Color(red: 0.055, green: 0.067, blue: 0.086) // panels
    static let cyan    = Color(red: 0.212, green: 0.886, blue: 1.0)   // #36E2FF
    static let violet  = Color(red: 0.482, green: 0.357, blue: 1.0)   // #7B5BFF
    static let pink    = Color(red: 1.0,   green: 0.302, blue: 0.616) // #FF4D9D
    static let route   = Color(red: 0.169, green: 0.878, blue: 0.541) // #2BE08A
    static let text    = Color(white: 0.92)
    static let muted   = Color(white: 0.55)

    static let auroraGradient = LinearGradient(
        colors: [cyan, violet, pink], startPoint: .leading, endPoint: .trailing)

    // Glanceable numerics — large, rounded, high-contrast for sunlight.
    static func heroNumber(_ size: CGFloat = 52) -> Font { .system(size: size, weight: .heavy, design: .rounded) }
    static let unitLabel = Font.system(size: 11, weight: .bold, design: .rounded)
}

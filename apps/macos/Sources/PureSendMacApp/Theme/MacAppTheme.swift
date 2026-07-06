import AppKit
import SwiftUI

enum MacAppTheme {
    static var windowBackground: LinearGradient {
        LinearGradient(
            colors: [backgroundTop, backgroundBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static let backgroundTop = Color.adaptive(
        light: NSColor(calibratedRed: 0.992, green: 0.997, blue: 1.0, alpha: 1),
        dark: NSColor(calibratedRed: 0.090, green: 0.090, blue: 0.092, alpha: 1)
    )
    static let backgroundBottom = Color.adaptive(
        light: NSColor(calibratedRed: 0.952, green: 0.985, blue: 1.0, alpha: 1),
        dark: NSColor(calibratedRed: 0.070, green: 0.070, blue: 0.072, alpha: 1)
    )
    static let cardSurface = Color.adaptive(
        light: NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.94),
        dark: NSColor(calibratedRed: 0.120, green: 0.120, blue: 0.124, alpha: 0.94)
    )
    static let elevatedSurface = Color.adaptive(
        light: NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.98),
        dark: NSColor(calibratedRed: 0.170, green: 0.170, blue: 0.176, alpha: 0.96)
    )
    static let softSurface = Color.adaptive(
        light: NSColor(calibratedRed: 0.982, green: 0.995, blue: 1.0, alpha: 0.96),
        dark: NSColor(calibratedRed: 0.095, green: 0.095, blue: 0.098, alpha: 0.96)
    )
    static let blueSurface = Color.adaptive(
        light: NSColor(calibratedRed: 0.910, green: 0.965, blue: 1.0, alpha: 0.94),
        dark: NSColor(calibratedRed: 0.155, green: 0.155, blue: 0.162, alpha: 0.94)
    )
    static let border = Color.adaptive(
        light: NSColor(calibratedRed: 0.560, green: 0.740, blue: 0.980, alpha: 0.30),
        dark: NSColor(calibratedRed: 0.390, green: 0.390, blue: 0.405, alpha: 0.28)
    )
    static let subtleBorder = Color.adaptive(
        light: NSColor(calibratedRed: 0.640, green: 0.800, blue: 0.990, alpha: 0.18),
        dark: NSColor(calibratedRed: 0.340, green: 0.340, blue: 0.355, alpha: 0.24)
    )
    static let shadow = Color.adaptive(
        light: NSColor(calibratedRed: 0.060, green: 0.160, blue: 0.300, alpha: 0.105),
        dark: NSColor(calibratedRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.38)
    )
    static let softShadow = Color.adaptive(
        light: NSColor(calibratedRed: 0.060, green: 0.160, blue: 0.300, alpha: 0.075),
        dark: NSColor(calibratedRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.28)
    )
    static let activeBorder = Color.adaptive(
        light: NSColor(calibratedRed: 0.180, green: 0.520, blue: 0.950, alpha: 0.58),
        dark: NSColor(calibratedRed: 0.570, green: 0.570, blue: 0.590, alpha: 0.38)
    )
    static let accent = Color.adaptive(
        light: NSColor.systemBlue,
        dark: NSColor(calibratedRed: 0.760, green: 0.760, blue: 0.780, alpha: 1)
    )
    static let accentMuted = Color.adaptive(
        light: NSColor.systemBlue.withAlphaComponent(0.72),
        dark: NSColor(calibratedRed: 0.650, green: 0.650, blue: 0.670, alpha: 0.72)
    )
}

private extension Color {
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

import SwiftUI

enum ZeehoTheme {
    static let primary = Color(hex: 0xA9C7FF)
    static let onPrimary = Color(hex: 0x00315C)
    static let primaryContainer = Color(hex: 0x2A4A73)
    static let onPrimaryContainer = Color(hex: 0xD6E3FF)
    static let secondaryContainer = Color(hex: 0x3E4759)
    static let onSecondaryContainer = Color(hex: 0xDCE2F5)
    static let tertiaryContainer = Color(hex: 0x5C4033)
    static let onTertiaryContainer = Color(hex: 0xFFDBCD)
    static let errorContainer = Color(hex: 0x93000A)
    static let onErrorContainer = Color(hex: 0xFFDAD6)
    static let surface = Color(hex: 0x111318)
    static let surfaceContainer = Color(hex: 0x1D2024)
    static let surfaceContainerHigh = Color(hex: 0x282A2E)
    static let surfaceContainerHighest = Color(hex: 0x333538)
    static let onSurface = Color(hex: 0xE2E2E6)
    static let onSurfaceVariant = Color(hex: 0xC3C6CF)
    static let outline = Color(hex: 0x8D9199)
    static let outlineVariant = Color(hex: 0x43474E)
    static let chargeContainer = Color(hex: 0x0E5C34)
    static let onChargeContainer = Color(hex: 0xB6F5C8)
}

enum ZeehoFont {
    static let labelSmall = Font.system(size: 11, weight: .medium)
    static let label = Font.system(size: 12, weight: .medium)
    static let labelLarge = Font.system(size: 14, weight: .medium)
    static let title = Font.system(size: 16, weight: .medium)
    static let headline = Font.system(size: 24, weight: .regular)
    static let display = Font.system(size: 36, weight: .regular)
    static let body = Font.system(size: 14, weight: .regular)
    static let bodySmall = Font.system(size: 12, weight: .regular)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

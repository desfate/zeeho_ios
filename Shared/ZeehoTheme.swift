import SwiftUI
import UIKit

struct ZeehoSkin: Codable, Equatable, Sendable {
    var accent: UInt32 = 0xA9C7FF
    var widgetBackground: UInt32 = 0x111318
    var widgetItem: UInt32 = 0x282A2E
    var useImage = false
}

enum ZeehoSkinStore {
    static let presets: [UInt32] = [0xA9C7FF, 0x7DFFD1, 0x8BE08B, 0xFFD56A, 0xFFB086, 0xFF8A80, 0xD4B3FF]
    static let backgroundPresets: [UInt32] = [0x000000, 0x111318, 0x1C1C1E, 0x0D1B2A, 0x1A2332, 0x1B2E1B, 0x2A1A1A]
    static let itemPresets: [UInt32] = [0x000000, 0x1A1C20, 0x282A2E, 0x333538, 0x3E4759, 0x2A4A73, 0x3D3424]

    private static let lock = NSLock()
    private static var cached = ZeehoSkin()
    private static var stamp: Date?

    static func current() -> ZeehoSkin {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL()
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if modified != stamp {
            cached = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ZeehoSkin.self, from: $0) } ?? ZeehoSkin()
            stamp = modified
        }
        return cached
    }

    static func save(_ skin: ZeehoSkin) {
        var next = skin
        next.widgetBackground |= 0xFF000000
        next.widgetItem |= 0xFF000000
        next.accent &= 0xFFFFFF
        if let data = try? JSONEncoder().encode(next) {
            try? data.write(to: fileURL(), options: .atomic)
        }
        lock.lock()
        cached = next
        stamp = (try? fileURL().resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        lock.unlock()
    }

    static func imageData() -> Data? {
        let url = imageURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func saveImage(_ image: UIImage) {
        let scaled = scaleDown(image, maxSide: 1280)
        guard let data = scaled.jpegData(compressionQuality: 0.85) else { return }
        try? data.write(to: imageURL(), options: .atomic)
        var skin = current()
        skin.useImage = true
        save(skin)
    }

    static func clearImage() {
        try? FileManager.default.removeItem(at: imageURL())
        var skin = current()
        skin.useImage = false
        save(skin)
    }

    static func parseHex(_ raw: String) -> UInt32? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard text.count == 6 || text.count == 8, let value = UInt32(text, radix: 16) else { return nil }
        return text.count == 6 ? value : (value & 0xFFFFFF)
    }

    private static func fileURL() -> URL {
        ZeehoFiles.directory().appendingPathComponent("appearance.json")
    }

    private static func imageURL() -> URL {
        ZeehoFiles.directory().appendingPathComponent("widget-bg.jpg")
    }

    private static func scaleDown(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide else { return image }
        let scale = maxSide / longest
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

enum ZeehoTheme {
    static var primary: Color { Color(hex: ZeehoSkinStore.current().accent) }
    static var onPrimary: Color { luminance(ZeehoSkinStore.current().accent) > 0.62 ? Color(hex: 0x111318) : .white }
    static var primaryContainer: Color { blend(ZeehoSkinStore.current().accent, 0x111318, 0.72) }
    static var onPrimaryContainer: Color { blend(ZeehoSkinStore.current().accent, 0xFFFFFF, 0.72) }
    static var secondaryContainer: Color { blend(0x3E4759, ZeehoSkinStore.current().accent, 0.22) }
    static var onSecondaryContainer: Color { blend(0xDCE2F5, ZeehoSkinStore.current().accent, 0.18) }
    static let tertiaryContainer = Color(hex: 0x5C4033)
    static let onTertiaryContainer = Color(hex: 0xFFDBCD)
    static let errorContainer = Color(hex: 0x93000A)
    static let onErrorContainer = Color(hex: 0xFFDAD6)
    static let surface = Color(hex: 0x111318)
    static var surfaceContainer: Color { blend(0x1D2024, ZeehoSkinStore.current().accent, 0.14) }
    static var surfaceContainerHigh: Color { blend(0x282A2E, ZeehoSkinStore.current().accent, 0.16) }
    static var surfaceContainerHighest: Color { blend(0x333538, ZeehoSkinStore.current().accent, 0.12) }
    static let onSurface = Color(hex: 0xE2E2E6)
    static let onSurfaceVariant = Color(hex: 0xC3C6CF)
    static let outline = Color(hex: 0x8D9199)
    static let outlineVariant = Color(hex: 0x43474E)
    static let chargeContainer = Color(hex: 0x0E5C34)
    static let onChargeContainer = Color(hex: 0xB6F5C8)
    static var widgetBackground: Color { Color(hex: ZeehoSkinStore.current().widgetBackground) }
    static var widgetItem: Color {
        let skin = ZeehoSkinStore.current()
        return Color(hex: skin.widgetItem).opacity(skin.useImage && ZeehoSkinStore.imageData() != nil ? 0.62 : 1)
    }

    private static func blend(_ from: UInt32, _ to: UInt32, _ amount: Double) -> Color {
        let t = min(1, max(0, amount))
        func channel(_ hex: UInt32, _ shift: UInt32) -> Double { Double((hex >> shift) & 0xFF) }
        return Color(
            .sRGB,
            red: (channel(from, 16) + (channel(to, 16) - channel(from, 16)) * t) / 255,
            green: (channel(from, 8) + (channel(to, 8) - channel(from, 8)) * t) / 255,
            blue: (channel(from, 0) + (channel(to, 0) - channel(from, 0)) * t) / 255
        )
    }

    private static func luminance(_ hex: UInt32) -> Double {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
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

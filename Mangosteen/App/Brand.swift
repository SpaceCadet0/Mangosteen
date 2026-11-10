import AppKit
import SwiftUI

/// Mangosteen's colours. The accent replaces the system accent in the wheel, the menu, tool windows and selections,
/// so the app looks the same whatever accent macOS uses. It is the brand's #671E38 unless another colour is chosen
/// in Settings → Appearance.
enum Brand {
    /// #671E38, the colour of the fruit's rind.
    static let wine = NSColor(srgbRed: 0x67 / 255.0, green: 0x1E / 255.0, blue: 0x38 / 255.0, alpha: 1)
    /// The brand's own lighter wine for text on dark backgrounds (4.7:1 on dark windows).
    private static let wineOnDark = NSColor(srgbRed: 0xCC / 255.0, green: 0x68 / 255.0, blue: 0x90 / 255.0, alpha: 1)

    struct Preset: Identifiable {
        let hex: String
        let name: String
        var id: String { hex }
        var color: NSColor { Brand.color(hex: hex) ?? Brand.wine }
    }

    /// Ready-made accents; all are dark enough for white text and get a lighter shade in dark mode.
    static var presets: [Preset] {
        [
            Preset(hex: "", name: String(localized: "Мангустин")),
            Preset(hex: "#1F5FBF", name: String(localized: "Синий")),
            Preset(hex: "#0E7C7B", name: String(localized: "Бирюзовый")),
            Preset(hex: "#2E7D32", name: String(localized: "Зелёный")),
            Preset(hex: "#C2410C", name: String(localized: "Оранжевый")),
            Preset(hex: "#5B3FA8", name: String(localized: "Фиолетовый")),
            Preset(hex: "#B0306A", name: String(localized: "Розовый")),
            Preset(hex: "#4A4A4F", name: String(localized: "Графит")),
        ]
    }

    /// The accent as chosen, for fills (the lit wheel slice and menu row).
    static var nsColor: NSColor { color(hex: AppSettings.shared.accentHex) ?? wine }

    /// The interface accent: the chosen colour in light mode; in dark mode a lighter shade, so tinted text (button
    /// titles, links) stays readable on dark backgrounds.
    static let adaptive = NSColor(name: "MangosteenAccent") { appearance in
        guard appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil else { return nsColor }
        return AppSettings.shared.accentHex.isEmpty ? wineOnDark : readable(nsColor, on: NSColor(white: 0.17, alpha: 1))
    }
    static var color: Color { Color(nsColor: adaptive) }

    /// Text and symbols drawn on an accent fill: white or black, whichever stands out more.
    static var onAccent: NSColor {
        contrast(.white, nsColor) >= contrast(.black, nsColor) ? .white : .black
    }

    /// A lighter tint of the accent for marks drawn on dark backgrounds (waveforms).
    static var light: Color { Color(nsColor: nsColor.blended(withFraction: 0.45, of: .white) ?? nsColor) }

    // MARK: Colour helpers

    /// "#RRGGBB" → colour; nil for an empty or malformed string.
    static func color(hex: String) -> NSColor? {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "" }
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }

    /// Relative luminance (WCAG).
    static func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }

    static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    /// `color` lightened towards white just enough to reach 4.5:1 against `background`.
    static func readable(_ color: NSColor, on background: NSColor) -> NSColor {
        var fraction: CGFloat = 0
        var result = color
        while contrast(result, background) < 4.5, fraction < 1 {
            fraction += 0.05
            result = color.blended(withFraction: fraction, of: .white) ?? color
        }
        return result
    }
}

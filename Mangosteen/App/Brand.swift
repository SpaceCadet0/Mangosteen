import AppKit
import SwiftUI

/// Mangosteen's colours. The brand colour replaces the system accent in the wheel, tool windows and
/// selections, so the app looks the same whatever accent the user has chosen.
enum Brand {
    /// #671E38, the colour of the fruit's rind.
    static let nsColor = NSColor(srgbRed: 0x67 / 255.0, green: 0x1E / 255.0, blue: 0x38 / 255.0, alpha: 1)
    /// The interface accent: exactly #671E38 in light mode; in dark mode a lighter wine so tinted text
    /// (button titles, links) stays readable on dark backgrounds.
    static let adaptive = NSColor(name: "MangosteenAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(srgbRed: 0xCC / 255.0, green: 0x68 / 255.0, blue: 0x90 / 255.0, alpha: 1) // 4.7:1 on dark windows
            : nsColor
    }
    static let color = Color(nsColor: adaptive)
    /// A lighter tint of the brand for marks drawn on dark backgrounds (waveforms).
    static let light = Color(red: 0.82, green: 0.45, blue: 0.58)
}

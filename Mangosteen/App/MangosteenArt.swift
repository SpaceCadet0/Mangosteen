import AppKit

/// The mangosteen drawn in code: a cross-section whose white segments echo the wheel.
/// Used for the app icon (colour) and the menu bar icon (template, tinted by macOS).
enum MangosteenArt {
    /// Segment spans in degrees (sum 360), lengths and tints differ slightly, like a real fruit.
    private static let spans: [CGFloat] = [64, 55, 61, 57, 66, 57]
    private static let lengths: [CGFloat] = [1.0, 0.95, 0.985, 0.93, 1.0, 0.96]
    private static let tints: [NSColor] = [
        NSColor(red: 1.0, green: 0.99, blue: 0.98, alpha: 1),
        NSColor(red: 0.99, green: 0.97, blue: 0.97, alpha: 1),
        NSColor(red: 1.0, green: 0.98, blue: 0.96, alpha: 1),
        NSColor(red: 0.98, green: 0.96, blue: 0.97, alpha: 1),
        NSColor(red: 1.0, green: 0.99, blue: 0.97, alpha: 1),
        NSColor(red: 0.99, green: 0.97, blue: 0.96, alpha: 1),
    ]
    private static let startAngle: CGFloat = 97

    private static func point(_ center: CGPoint, _ radius: CGFloat, _ degrees: CGFloat) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: center.x + radius * cos(radians), y: center.y + radius * sin(radians))
    }

    /// A wedge with rounded corners whose straight edges stay `gap` away from the neighbours.
    private static func segment(center: CGPoint, radius: CGFloat, from start: CGFloat, span: CGFloat,
                                gap: CGFloat, corner: CGFloat) -> CGPath {
        let inset = gap / 2 + corner
        let outer = radius - corner
        let halfSpan = span / 2 * .pi / 180
        let tipRadius = inset / sin(halfSpan)
        let edgeAngle = asin(min(inset / outer, 1)) * 180 / .pi
        let path = CGMutablePath()
        path.move(to: point(center, tipRadius, start + span / 2))
        path.addLine(to: point(center, outer, start + edgeAngle))
        path.addArc(center: center, radius: outer, startAngle: (start + edgeAngle) * .pi / 180,
                    endAngle: (start + span - edgeAngle) * .pi / 180, clockwise: false)
        path.closeSubpath()
        // Growing the shape by its stroke rounds every corner; a true union avoids winding holes.
        let stroke = path.copy(strokingWithWidth: corner * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
        return path.union(stroke)
    }

    // MARK: - Colour icon

    /// Draws the fruit filling `rect` (transparent outside the circle). `detailed` adds the speckled rind.
    static func drawIcon(in rect: CGRect, context: CGContext, detailed: Bool) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 * 0.94
        let space = CGColorSpace(name: CGColorSpace.sRGB)!

        func circle(_ r: CGFloat) -> CGRect { CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2) }
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: space, components: [r, g, b, a])!
        }

        // Soft drop shadow under the fruit.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -radius * 0.03), blur: radius * 0.06,
                          color: color(0.2, 0.02, 0.1, 0.45))
        context.setFillColor(color(0.45, 0.08, 0.22))
        context.fillEllipse(in: circle(radius))
        context.restoreGState()

        // Rind: deep wine purple, lighter towards the upper left.
        context.saveGState()
        context.addEllipse(in: circle(radius))
        context.clip()
        let rind = CGGradient(colorsSpace: space, colors: [color(0.58, 0.16, 0.30), color(0.36, 0.06, 0.19)] as CFArray,
                              locations: [0, 1])!
        context.drawRadialGradient(rind, startCenter: CGPoint(x: center.x - radius * 0.3, y: center.y + radius * 0.35),
                                   startRadius: 0, endCenter: center, endRadius: radius * 1.05,
                                   options: [.drawsAfterEndLocation])
        context.restoreGState()

        // The reddish inner layer of the rind, fading into the darker outer skin.
        let rim = radius * 0.82
        context.saveGState()
        context.addEllipse(in: circle(rim))
        context.clip()
        let inner = CGGradient(colorsSpace: space, colors: [color(0.62, 0.2, 0.3), color(0.5, 0.12, 0.24)] as CFArray,
                               locations: [0.8, 1])!
        context.drawRadialGradient(inner, startCenter: center, startRadius: 0, endCenter: center, endRadius: rim,
                                   options: [.drawsAfterEndLocation])
        context.restoreGState()

        if detailed {
            // A light, deterministic speckle on the rind and the inner layer.
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            func random() -> CGFloat {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
            }
            for _ in 0..<160 {
                let distance = radius * (0.74 + random() * 0.24)
                let angle = random() * 360
                let size = radius * (0.006 + random() * 0.012)
                let spot = point(center, distance, angle)
                let light = random() > 0.45
                context.setFillColor(light ? color(0.86, 0.45, 0.45, 0.35) : color(0.25, 0.03, 0.1, 0.35))
                context.fillEllipse(in: CGRect(x: spot.x - size, y: spot.y - size, width: size * 2, height: size * 2))
            }
        }

        // Dark well between the segments.
        let flesh = radius * 0.72
        context.setFillColor(color(0.28, 0.04, 0.13))
        context.fillEllipse(in: circle(flesh))

        // The white segments.
        var angle = startAngle
        for index in spans.indices {
            let path = segment(center: center, radius: flesh * 0.985 * lengths[index], from: angle, span: spans[index],
                               gap: flesh * 0.035, corner: flesh * 0.14)
            context.saveGState()
            context.addPath(path)
            context.clip()
            let tint = tints[index].usingColorSpace(.sRGB) ?? .white
            let edge = color(tint.redComponent, tint.greenComponent, tint.blueComponent)
            let shade = color(tint.redComponent * 0.86, tint.greenComponent * 0.8, tint.blueComponent * 0.82)
            let gradient = CGGradient(colorsSpace: space, colors: [shade, edge, edge] as CFArray, locations: [0, 0.55, 1])!
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                       endRadius: flesh, options: [.drawsAfterEndLocation])
            context.restoreGState()
            angle += spans[index]
        }
    }

    static func appIcon(size: CGFloat = 1024) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            drawIcon(in: rect, context: context, detailed: rect.width >= 64)
            return true
        }
    }

    // MARK: - Menu bar icon

    /// A monochrome ring with the segments, for the status item; macOS tints template images.
    static func menuBarIcon(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = size / 2 - 0.75
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            let flesh = radius - 1.9
            context.setFillColor(NSColor.black.cgColor)
            var angle = startAngle
            for index in spans.indices {
                context.addPath(segment(center: center, radius: flesh * lengths[index], from: angle, span: spans[index],
                                        gap: 1.0, corner: 0.45))
                context.fillPath()
                angle += spans[index]
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

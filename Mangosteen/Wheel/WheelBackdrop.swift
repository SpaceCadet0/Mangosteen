import AppKit
import SwiftUI

/// What lies behind the wheel. Without the glass effect it is a blur of whatever is under the wheel, as under the
/// system menus; the lower the opacity, the smaller the blur radius and the thinner its grey, so at 40% the
/// background is softly blurred but keeps its shapes and colours.
/// With the glass effect (macOS 26) every segment and the centre are a piece of Liquid Glass of exactly their shape,
/// so the glass bends the light at each edge and the background shows through the gaps. AppKit's glass view only
/// takes rounded rectangles, so the pieces are SwiftUI glass. The lit segment is painted by the wheel itself, at
/// once: changing the glass on every hover lagged behind the pointer. It never takes clicks or drops.
final class WheelBackdrop: NSView {
    /// Shaped glass: the wheel then paints no background, only the lit segment.
    let isGlass: Bool
    private let model: AnyObject?
    private var blur: NSVisualEffectView?

    /// `glass` is honoured on macOS 26 and later; earlier systems always get the blur.
    init(frame frameRect: NSRect, glass: Bool) {
        if glass, #available(macOS 26.0, *) {
            let model = GlassModel()
            self.model = model
            isGlass = true
            super.init(frame: frameRect)
            let host = PassiveHostingView(rootView: GlassWheel(model: model))
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
        } else {
            model = nil
            isGlass = false
            super.init(frame: frameRect)
            let ring = WheelView.outerRadius * 2
            let blur = NSVisualEffectView(frame: NSRect(x: bounds.midX - ring / 2, y: bounds.midY - ring / 2, width: ring, height: ring))
            blur.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            // The menu material follows light and dark mode like the system's own menus.
            blur.material = .menu
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.maskImage = NSImage(size: blur.frame.size, flipped: false) { rect in
                NSBezierPath(ovalIn: rect).fill()
                return true
            }
            addSubview(blur)
            self.blur = blur
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 0 at the lowest opacity setting (40%), 1 at the default (96%) and above.
    static func blurStrength(opacity: Double) -> Double {
        min(max((opacity - 0.4) / 0.56, 0), 1)
    }

    /// Blur radius in points for an opacity setting: a light blur at 40%, the system menus' 30 at the default.
    static func blurRadius(opacity: Double) -> Double {
        8 + 22 * blurStrength(opacity: opacity)
    }

    private var opacity = 0.96

    /// The segments of the side showing and the opacity setting.
    func update(segments: Int, opacity: Double) {
        self.opacity = opacity
        tuneBlur()
        // The material may build its layers only once the panel is on screen.
        DispatchQueue.main.async { [weak self] in self?.tuneBlur() }
        guard #available(macOS 26.0, *), let model = model as? GlassModel else { return }
        if model.segments != segments { model.segments = segments }
        if model.opacity != opacity { model.opacity = opacity }
    }

    /// The material's blur has a fixed 30-point radius under a 70% grey fill, which turns a light wallpaper into one
    /// flat colour. Its layers are the material's own (`CABackdropLayer` with a `gaussianBlur` filter, then "fill");
    /// they are tuned by name, and if a future macOS names them differently the material simply stays as it is.
    private func tuneBlur() {
        guard let root = blur?.layer else { return }
        let strength = Self.blurStrength(opacity: opacity)
        let radius = Self.blurRadius(opacity: opacity)
        func visit(_ layer: CALayer) {
            if String(describing: type(of: layer)) == "CABackdropLayer",
               layer.value(forKeyPath: "filters.gaussianBlur.inputRadius") != nil {
                layer.setValue(radius, forKeyPath: "filters.gaussianBlur.inputRadius")
                // The backdrop is sampled at 1/8 size for the 30-point blur; a lighter blur needs finer sampling or
                // it turns blocky.
                if layer.value(forKey: "scale") != nil { layer.setValue(min(1, 4 / radius), forKey: "scale") }
            } else if layer.name == "fill" {
                layer.opacity = Float(0.2 + 0.8 * strength)
            }
            layer.sublayers?.forEach(visit)
        }
        visit(root)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The material rebuilds its layers for light and dark mode.
        DispatchQueue.main.async { [weak self] in self?.tuneBlur() }
    }
}

/// SwiftUI's hosting view registers itself for drags again whenever it updates, so unregistering once is not
/// enough; drops and hover belong to the wheel above.
private final class PassiveHostingView<Content: View>: NSHostingView<Content> {
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@available(macOS 26.0, *)
private final class GlassModel: ObservableObject {
    @Published var segments = 0
    @Published var opacity = 0.96
}

@available(macOS 26.0, *)
private struct GlassWheel: View {
    @ObservedObject var model: GlassModel

    /// Below 70% opacity the glass is clear and barely tinted, like glass over a picture; above it, the regular glass
    /// takes more of the window colour so labels stay readable over busy backgrounds.
    private var glass: Glass {
        if model.opacity < 0.7 {
            return Glass.clear.tint(Color(nsColor: .windowBackgroundColor).opacity((model.opacity - 0.4) * 0.5))
        }
        return Glass.regular.tint(Color(nsColor: .windowBackgroundColor).opacity((model.opacity - 0.7) * 1.2))
    }

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            ZStack {
                ForEach(0..<model.segments, id: \.self) { index in
                    Color.clear.glassEffect(glass, in: SegmentShape(index: index, count: model.segments))
                }
                Color.clear.glassEffect(glass, in: CentreShape())
            }
        }
        // The wheel's panel never becomes key (it must not take focus from Finder), and glass in an inactive window may
        // be drawn dimmed; the wheel is always what the user is looking at.
        .environment(\.appearsActive, true)
        .environment(\.controlActiveState, .key)
    }
}

/// One segment, the same path the wheel draws, turned from AppKit's y-up into SwiftUI's y-down space.
private struct SegmentShape: Shape {
    let index: Int
    let count: Int

    func path(in rect: CGRect) -> Path {
        let path = WheelView.segmentCGPath(index: index, count: count, center: CGPoint(x: rect.midX, y: rect.midY))
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rect.minY + rect.maxY)
        return Path(path.copy(using: &flip) ?? path)
    }
}

private struct CentreShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = WheelView.innerRadius - 2
        return Path(ellipseIn: CGRect(x: rect.midX - radius, y: rect.midY - radius, width: radius * 2, height: radius * 2))
    }
}

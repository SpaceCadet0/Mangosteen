import CoreImage
import Foundation

/// An sRGB colour that can be stored in settings and compared.
struct RGBAColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, alpha])!
    }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: CGColor) {
        let converted = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
        let components = converted?.components ?? [0, 0, 0, 1]
        if components.count >= 3 {
            self.init(red: components[0], green: components[1], blue: components[2], alpha: components.last ?? 1)
        } else {
            self.init(red: components[0], green: components[0], blue: components[0], alpha: components.last ?? 1)
        }
    }

    static let white = RGBAColor(red: 1, green: 1, blue: 1)
}

/// Canvas proportions shared by Background and Collage.
enum CanvasAspect: String, CaseIterable, Identifiable {
    case auto, square, r4x5, r5x4, r4x3, r3x4, r3x2, r2x3, r16x9, r9x16

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: String(localized: "Авто")
        case .square: "1:1"
        case .r4x5: "4:5"
        case .r5x4: "5:4"
        case .r4x3: "4:3"
        case .r3x4: "3:4"
        case .r3x2: "3:2"
        case .r2x3: "2:3"
        case .r16x9: "16:9"
        case .r9x16: "9:16"
        }
    }

    var ratio: CGFloat? {
        switch self {
        case .auto: nil
        case .square: 1
        case .r4x5: 4.0 / 5
        case .r5x4: 5.0 / 4
        case .r4x3: 4.0 / 3
        case .r3x4: 3.0 / 4
        case .r3x2: 3.0 / 2
        case .r2x3: 2.0 / 3
        case .r16x9: 16.0 / 9
        case .r9x16: 9.0 / 16
        }
    }
}

struct FrameSettings: Equatable {
    enum Background: String, CaseIterable, Identifiable {
        case color, gradient, image, blur
        var id: String { rawValue }
        var title: String {
            switch self {
            case .color: String(localized: "Цвет")
            case .gradient: String(localized: "Градиент")
            case .image: String(localized: "Изображение")
            case .blur: String(localized: "Исходное изображение")
            }
        }
    }

    var background = Background.gradient
    var color = RGBAColor(red: 0.96, green: 0.95, blue: 0.93)
    var gradientStart = RGBAColor(red: 0.98, green: 0.62, blue: 0.36)
    var gradientEnd = RGBAColor(red: 0.55, green: 0.27, blue: 0.68)
    /// Degrees, 0 = left → right, 90 = bottom → top.
    var gradientAngle = 135.0
    var backgroundImage: URL?
    /// 0…1, used by the image and blur backgrounds.
    var blur = 0.5
    var aspect = CanvasAspect.auto
    /// Margin around the photo as a fraction of its longer side.
    var padding = 0.08
    /// Corner radius as a fraction of the photo's shorter side.
    var cornerRadius = 0.03
    /// «Круг»: the photo is cut to its centred square and fully rounded; `cornerRadius` is not used.
    var circle = false
    /// 0…1
    var shadow = 0.5
}

/// Places a photo on a new canvas: colour, gradient, image or blurred backdrop, with margin, corners and shadow.
enum FrameComposer {
    static func canvasSize(photo: CGSize, settings: FrameSettings) -> CGSize {
        let margin = settings.padding * max(photo.width, photo.height)
        var size = CGSize(width: photo.width + margin * 2, height: photo.height + margin * 2)
        if let ratio = settings.aspect.ratio {
            if size.width / size.height < ratio {
                size.width = size.height * ratio
            } else {
                size.height = size.width / ratio
            }
        }
        return CGSize(width: size.width.rounded(), height: size.height.rounded())
    }

    static func compose(_ source: CGImage, settings: FrameSettings, backgroundImage: CGImage? = nil) throws -> CGImage {
        let photo = settings.circle ? (centredSquare(source) ?? source) : source
        let photoSize = CGSize(width: photo.width, height: photo.height)
        let size = canvasSize(photo: photoSize, settings: settings)
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ConversionError.encodeFailed(.png)
        }
        context.interpolationQuality = .high
        let canvas = CGRect(origin: .zero, size: size)
        let longest = max(size.width, size.height)

        switch settings.background {
        case .color:
            context.setFillColor(settings.color.cgColor)
            context.fill(canvas)
        case .gradient:
            drawGradient(in: context, rect: canvas, from: settings.gradientStart, to: settings.gradientEnd,
                         angle: settings.gradientAngle)
        case .image, .blur:
            let backdrop = settings.background == .blur ? photo : (backgroundImage ?? photo)
            let blurred = settings.blur > 0 ? try blurredImage(backdrop, radius: settings.blur * longest * 0.04) : backdrop
            drawAspectFill(blurred, in: context, rect: canvas)
        }

        let photoRect = CGRect(x: (size.width - photoSize.width) / 2, y: (size.height - photoSize.height) / 2,
                               width: photoSize.width, height: photoSize.height)
        let radius = (settings.circle ? 0.5 : settings.cornerRadius) * min(photoSize.width, photoSize.height)
        let shape = CGPath(roundedRect: photoRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        context.saveGState()
        if settings.shadow > 0 {
            let blur = settings.shadow * longest * 0.035
            context.setShadow(offset: CGSize(width: 0, height: -blur * 0.35), blur: blur,
                              color: CGColor(gray: 0, alpha: 0.25 + settings.shadow * 0.3))
        }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.addPath(shape)
        context.clip()
        context.draw(photo, in: photoRect)
        context.endTransparencyLayer()
        context.restoreGState()

        guard let result = context.makeImage() else { throw ConversionError.encodeFailed(.png) }
        return result
    }

    static func drawGradient(in context: CGContext, rect: CGRect, from start: RGBAColor, to end: RGBAColor, angle: Double) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [start.cgColor, end.cgColor] as CFArray, locations: [0, 1]) else {
            return
        }
        let radians = CGFloat(angle) * .pi / 180
        let cosine: CGFloat = cos(radians)
        let sine: CGFloat = sin(radians)
        // Half the length of the gradient line that spans the rectangle at this angle.
        let half: CGFloat = (abs(cosine) * rect.width + abs(sine) * rect.height) / 2
        let delta = CGPoint(x: cosine * half, y: sine * half)
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: rect.midX - delta.x, y: rect.midY - delta.y),
                                   end: CGPoint(x: rect.midX + delta.x, y: rect.midY + delta.y),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// Scales `image` to cover `rect`, centred and clipped.
    static func drawAspectFill(_ image: CGImage, in context: CGContext, rect: CGRect) {
        let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.saveGState()
        context.clip(to: rect)
        context.draw(image, in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                       width: size.width, height: size.height))
        context.restoreGState()
    }

    static func blurredImage(_ image: CGImage, radius: Double) throws -> CGImage {
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent()
            .applyingGaussianBlur(sigma: radius)
            .cropped(to: input.extent)
        return try PhotoEditor.render(output)
    }

    /// The largest square from the middle of `image`.
    private static func centredSquare(_ image: CGImage) -> CGImage? {
        let side = min(image.width, image.height)
        guard side != image.width || side != image.height else { return image }
        return image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side))
    }

    /// Writes `<name> (фон).<ext>` next to the original.
    static func composeFile(_ input: URL, settings: FrameSettings, options: ConversionOptions) throws -> URL {
        guard let source = FileFormat.detect(input) else { throw ConversionError.unrecognized(input) }
        let (photo, metadata) = try ImageConverter.load(input)
        let backdrop = try settings.backgroundImage.map { try ImageConverter.load($0, maxPixelSize: 4096).image }
        let result = try compose(photo, settings: settings, backgroundImage: backdrop)
        let target = FormatCatalog.editableImageFormats.contains(source) ? source : .png
        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: String(localized: "\(OutputNaming.baseName(of: input)) (фон)"),
            pathExtension: target.fileExtension
        ) { url in
            try ImageConverter.write(result, as: target, to: url, options: options,
                                     metadata: options.preserveMetadata ? metadata : nil)
        }
    }
}

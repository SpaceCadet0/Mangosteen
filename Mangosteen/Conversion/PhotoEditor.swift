import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Photo adjustments. Every value at its default leaves the image unchanged.
struct PhotoAdjustments: Equatable {
    enum Effect: String, CaseIterable, Identifiable {
        case none, mono, noir, tonal, chrome, fade, instant, process, transfer
        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: "Нет"
            case .mono: "Моно"
            case .noir: "Нуар"
            case .tonal: "Тональный"
            case .chrome: "Хром"
            case .fade: "Выцветание"
            case .instant: "Моментальный"
            case .process: "Процесс"
            case .transfer: "Перенос"
            }
        }

        var filterName: String? {
            switch self {
            case .none: nil
            case .mono: "CIPhotoEffectMono"
            case .noir: "CIPhotoEffectNoir"
            case .tonal: "CIPhotoEffectTonal"
            case .chrome: "CIPhotoEffectChrome"
            case .fade: "CIPhotoEffectFade"
            case .instant: "CIPhotoEffectInstant"
            case .process: "CIPhotoEffectProcess"
            case .transfer: "CIPhotoEffectTransfer"
            }
        }
    }

    // Light
    var exposure = 0.0       // EV, -2…2
    var brightness = 0.0     // -1…1
    var contrast = 0.0       // -1…1
    var highlights = 0.0     // -1…1 (negative recovers highlights)
    var shadows = 0.0        // -1…1 (positive lifts shadows)
    // Colour
    var temperature = 0.0    // -1 cooler … 1 warmer
    var tint = 0.0           // -1 green … 1 magenta
    var saturation = 0.0     // -1…1
    var vibrance = 0.0       // -1…1
    // Detail
    var sharpness = 0.0      // 0…1
    var clarity = 0.0        // 0…1
    var noiseReduction = 0.0 // 0…1
    var dehaze = 0.0         // 0…1
    // Effects
    var effect = Effect.none
    var vignette = 0.0       // 0…1
    var grain = 0.0          // 0…1

    var isIdentity: Bool { self == PhotoAdjustments() }
}

enum PhotoEditor {
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// `scale` is the preview size relative to the full image, so pixel-radius effects look the same.
    static func apply(_ adjustments: PhotoAdjustments, to input: CIImage, scale: Double = 1) -> CIImage {
        let extent = input.extent
        var image = input

        if adjustments.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = image
            filter.ev = Float(adjustments.exposure)
            image = filter.outputImage ?? image
        }
        if adjustments.highlights != 0 || adjustments.shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = image
            filter.highlightAmount = Float(1 + min(adjustments.highlights, 0))
            filter.shadowAmount = Float(adjustments.shadows)
            filter.radius = Float(10 * scale)
            image = filter.outputImage ?? image
        }
        let dehaze = adjustments.dehaze
        if adjustments.brightness != 0 || adjustments.contrast != 0 || adjustments.saturation != 0 || dehaze != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.brightness = Float(adjustments.brightness * 0.3 - dehaze * 0.05)
            filter.contrast = Float(1 + adjustments.contrast * 0.5 + dehaze * 0.25)
            filter.saturation = Float(1 + adjustments.saturation + dehaze * 0.2)
            image = filter.outputImage ?? image
        }
        if adjustments.vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = image
            filter.amount = Float(adjustments.vibrance)
            image = filter.outputImage ?? image
        }
        if adjustments.temperature != 0 || adjustments.tint != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = image
            filter.neutral = CIVector(x: 6500, y: 0)
            filter.targetNeutral = CIVector(x: 6500 - adjustments.temperature * 3000, y: adjustments.tint * 100)
            image = filter.outputImage ?? image
        }
        if adjustments.noiseReduction > 0 {
            let filter = CIFilter.noiseReduction()
            filter.inputImage = image
            filter.noiseLevel = Float(0.02 + adjustments.noiseReduction * 0.06)
            filter.sharpness = 0.4
            image = filter.outputImage ?? image
        }
        if adjustments.clarity > 0 || dehaze > 0 {
            // Local contrast: a large-radius unsharp mask.
            let filter = CIFilter.unsharpMask()
            filter.inputImage = image
            filter.radius = Float(40 * scale)
            filter.intensity = Float(adjustments.clarity * 0.8 + dehaze * 0.5)
            image = filter.outputImage ?? image
        }
        if adjustments.sharpness > 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = image
            filter.sharpness = Float(adjustments.sharpness * 1.5)
            filter.radius = Float(max(1.5 * scale, 0.5))
            image = filter.outputImage ?? image
        }
        if let name = adjustments.effect.filterName, let filter = CIFilter(name: name) {
            filter.setValue(image, forKey: kCIInputImageKey)
            image = filter.outputImage ?? image
        }
        if adjustments.vignette > 0 {
            let filter = CIFilter.vignetteEffect()
            filter.inputImage = image
            filter.center = CGPoint(x: extent.midX, y: extent.midY)
            filter.radius = Float(max(extent.width, extent.height) * 0.75)
            filter.intensity = Float(adjustments.vignette)
            filter.falloff = 0.5
            image = filter.outputImage ?? image
        }
        if adjustments.grain > 0, let noise = CIFilter.randomGenerator().outputImage {
            // Monochrome noise around mid-grey, overlaid so it adds texture without shifting tones.
            let grain = noise
                .transformed(by: CGAffineTransform(scaleX: max(scale, 0.5), y: max(scale, 0.5)))
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(adjustments.grain * 0.35)),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                ])
                .cropped(to: extent)
            image = grain.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: image])
        }
        return image.cropped(to: extent)
    }

    static func render(_ image: CIImage) throws -> CGImage {
        guard let output = context.createCGImage(image, from: image.extent,
                                                 format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw ConversionError.encodeFailed(.png)
        }
        return output
    }

    /// Writes `<name> (изменено).<ext>` next to the original, keeping format and metadata.
    static func applyFile(_ input: URL, adjustments: PhotoAdjustments, options: ConversionOptions) throws -> URL {
        guard let source = FileFormat.detect(input) else { throw ConversionError.unrecognized(input) }
        let (image, metadata) = try ImageConverter.load(input)
        let result = try render(apply(adjustments, to: CIImage(cgImage: image)))
        let target = FormatCatalog.imageOutputs.contains(source) && source != .pdf ? source : .png
        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: "\(OutputNaming.baseName(of: input)) (изменено)",
            pathExtension: target.fileExtension
        ) { url in
            try ImageConverter.write(result, as: target, to: url, options: options,
                                     metadata: options.preserveMetadata ? metadata : nil)
        }
    }
}

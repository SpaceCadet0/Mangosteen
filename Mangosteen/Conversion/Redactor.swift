import CoreImage
import Foundation
import Vision

/// An area to hide, in normalised coordinates (0…1, origin at the top-left of the upright image).
struct RedactionRegion: Identifiable, Equatable {
    var id = UUID()
    var rect: CGRect
}

enum RedactionStyle: String, CaseIterable, Identifiable {
    case solid, blur, pixelate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solid: String(localized: "Заливка")
        case .blur: String(localized: "Размытие")
        case .pixelate: String(localized: "Пиксели")
        }
    }
}

/// Finds faces and text on-device and covers regions irreversibly.
enum Redactor {
    enum Detection {
        case faces, text
    }

    /// Detected areas, slightly enlarged so edges are covered too.
    static func detect(_ detection: Detection, in image: CGImage) throws -> [CGRect] {
        let request: VNImageBasedRequest
        switch detection {
        case .faces:
            request = VNDetectFaceRectanglesRequest()
        case .text:
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = false
            request = text
        }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let boxes = (request.results as? [VNDetectedObjectObservation] ?? []).map(\.boundingBox)
        let margin: CGFloat = detection == .faces ? 0.15 : 0.08
        return boxes.map { box in
            // Vision uses a bottom-left origin.
            let flipped = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            return flipped
                .insetBy(dx: -flipped.width * margin, dy: -flipped.height * margin)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    static func apply(_ regions: [CGRect], style: RedactionStyle, color: RGBAColor, to image: CGImage) throws -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        var output = CIImage(cgImage: image)
        let extent = output.extent
        for normalized in regions {
            // Core Image uses a bottom-left origin.
            let pixels = ImageCropper.pixelRect(normalized, imageSize: size)
            let rect = CGRect(x: pixels.minX, y: size.height - pixels.maxY, width: pixels.width, height: pixels.height)
            guard rect.width >= 1, rect.height >= 1 else { continue }
            let cover: CIImage
            switch style {
            case .solid:
                cover = CIImage(color: CIColor(cgColor: color.cgColor)).cropped(to: rect)
            case .pixelate, .blur:
                // Pixelating first destroys detail, so even the blur cannot be reversed.
                let block = max(max(rect.width, rect.height) / 10, 8)
                var hidden = output.clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [
                        kCIInputScaleKey: block,
                        kCIInputCenterKey: CIVector(x: rect.minX, y: rect.minY),
                    ])
                if style == .blur {
                    hidden = hidden.applyingGaussianBlur(sigma: block * 0.8)
                }
                cover = hidden.cropped(to: rect)
            }
            output = cover.composited(over: output)
        }
        return try PhotoEditor.render(output.cropped(to: extent))
    }

    /// Writes `<name> (скрыто).<ext>` without any metadata, so location and camera data are not leaked.
    static func applyFile(_ input: URL, regions: [CGRect], style: RedactionStyle, color: RGBAColor,
                          options: ConversionOptions) throws -> URL {
        guard let source = FileFormat.detect(input) else { throw ConversionError.unrecognized(input) }
        let (image, _) = try ImageConverter.load(input)
        let result = try apply(regions, style: style, color: color, to: image)
        let target = FormatCatalog.imageOutputs.contains(source) && source != .pdf ? source : .png
        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: String(localized: "\(OutputNaming.baseName(of: input)) (скрыто)"),
            pathExtension: target.fileExtension
        ) { url in
            try ImageConverter.write(result, as: target, to: url, options: options, metadata: nil)
        }
    }
}

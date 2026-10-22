import CoreImage
import Foundation
import Vision

/// Removes the background behind the main subject of a photo with Vision's foreground mask (macOS 14+).
enum BackgroundRemover {
    enum Failure: LocalizedError {
        case noSubject(URL?)

        var errorDescription: String? {
            switch self {
            case .noSubject(let url):
                url.map { String(localized: "На «\($0.lastPathComponent)» не найден объект, от которого можно отделить фон.") }
                    ?? String(localized: "На фото не найден объект, от которого можно отделить фон.")
            }
        }
    }

    struct Options: Equatable {
        /// nil keeps the background transparent (PNG); a colour fills it.
        var fill: RGBAColor?
        /// Trim the picture to the subject's bounds.
        var cropToSubject = false
    }

    private static let context = CIContext()

    /// The subject on a transparent background, at the image's own size (or cropped to the subject).
    static func cutout(_ image: CGImage, cropToSubject: Bool) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw Failure.noSubject(nil)
        }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler,
                                                         croppedToInstancesExtent: cropToSubject)
        let masked = CIImage(cvPixelBuffer: buffer)
        guard let result = context.createCGImage(masked, from: masked.extent, format: .RGBA8,
                                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw Failure.noSubject(nil)
        }
        return result
    }

    /// Puts the cut-out subject on `fill`, or leaves it transparent.
    static func compose(_ cutout: CGImage, fill: RGBAColor?) throws -> CGImage {
        guard let fill else { return cutout }
        let width = cutout.width, height = cutout.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.encodeFailed(.png)
        }
        context.setFillColor(fill.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cutout, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ConversionError.encodeFailed(.png) }
        return result
    }

    /// Writes `<name> (без фона).png` next to the original; with a fill colour the original's format is kept
    /// when it can be written.
    static func removeFile(_ input: URL, options: Options, conversion: ConversionOptions) throws -> URL {
        let (image, metadata) = try ImageConverter.load(input)
        let subject: CGImage
        do {
            subject = try cutout(image, cropToSubject: options.cropToSubject)
        } catch Failure.noSubject {
            throw Failure.noSubject(input)
        }
        let result = try compose(subject, fill: options.fill)
        let source = FileFormat.detect(input)
        let target: FileFormat = options.fill != nil && source.map { FormatCatalog.editableImageFormats.contains($0) } == true
            ? source! : .png
        return try OutputNaming.writeAtomically(
            directory: input.deletingLastPathComponent(),
            baseName: String(localized: "\(OutputNaming.baseName(of: input)) (без фона)"),
            pathExtension: target.fileExtension
        ) { url in
            try ImageConverter.write(result, as: target, to: url, options: conversion,
                                     metadata: conversion.preserveMetadata ? metadata : nil)
        }
    }
}

import CoreGraphics
import Foundation

/// Turns a picture into vector shapes (SVG): a black-and-white trace for drawings, text and scans, or a few flat
/// colours for logos and icons. A photo becomes a poster of colour patches, which is what tracing does.
///
/// How: the picture is reduced to its main colours (k-means), each colour becomes a mask, the mask's boundaries are
/// followed along the pixel edges (every outline and hole is one loop; even-odd filling tells them apart), and the
/// loops are simplified and smoothed into Bézier curves. Following edges takes time in proportion to the picture;
/// Vision's contour request, used at first, took minutes on photos with thousands of patches. Layers are stacked
/// from the largest colour up, each covering its own area and everything painted after it, so no hairline gaps show
/// between neighbouring colours.
enum VectorTracer {
    struct Options: Equatable {
        /// 1 traces black on white; 2…16 keeps that many colours.
        var colors = 1
        /// 0…1: how much small detail and how many points survive.
        var detail = 0.6
        /// Curves through the points instead of straight segments.
        var smooth = true
        /// Black and white: draws only the ink, without the white paper behind it. Colours: leaves out the colour
        /// covering most of the picture's edge (usually the background). A transparent background stays transparent.
        var dropBackground = false
    }

    struct RGB: Equatable, Hashable {
        var red: Double
        var green: Double
        var blue: Double

        var hex: String {
            String(format: "#%02x%02x%02x", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
        }
    }

    struct Layer {
        var color: RGB
        /// In picture coordinates, y down (as in SVG).
        var path: CGPath
    }

    struct Result {
        var size: CGSize
        var layers: [Layer]
    }

    /// The traced picture is worked on at most this size; the shapes are scaled back to the original.
    /// 2000 keeps thin lines and small lettering; following edges takes a fraction of a second even at this size.
    static let workingSize = 2000

    // MARK: Tracing

    /// `isCancelled` is asked between layers and while following boundaries, so a preview that is no longer wanted
    /// stops early.
    static func trace(_ image: CGImage, options: Options, isCancelled: () -> Bool = { false }) throws -> Result {
        let size = CGSize(width: image.width, height: image.height)
        let pixels = try Pixels(image, maxSide: workingSize)
        let scale = CGFloat(image.width) / CGFloat(pixels.width)

        // Each pixel gets a colour index; -1 is transparent.
        var palette: [RGB]
        var labels: [Int]
        if options.colors <= 1 {
            // A transparent background is paper: a logo saved with no background is dark on nothing, and judged
            // by its visible pixels alone the threshold fell between the ink and its own soft edges.
            let threshold = otsuThreshold(pixels)
            labels = (0..<pixels.count).map { pixels.luminanceOnWhite($0) < threshold ? 1 : 0 }
            palette = [RGB(red: 1, green: 1, blue: 1), RGB(red: 0, green: 0, blue: 0)]
        } else {
            (palette, labels) = quantize(pixels, colors: min(max(options.colors, 2), 16))
        }

        // The largest colour first. In black-and-white mode the paper is one white rectangle under the ink.
        let minimumArea = pow(1 - options.detail, 2) * Double(pixels.count) * 0.0004 + 2
        var layers: [Layer] = []
        var areas = [Int](repeating: 0, count: palette.count)
        for label in labels where label >= 0 { areas[label] += 1 }
        var order = palette.indices.filter { areas[$0] > 0 }.sorted { areas[$0] > areas[$1] }
        if options.colors <= 1 {
            order = order.filter { $0 == 1 }
            if !options.dropBackground {
                layers.append(Layer(color: palette[0], path: CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)))
            }
        } else if options.dropBackground, let background = edgeColor(labels, width: pixels.width, height: pixels.height) {
            order.removeAll { $0 == background }
        }

        for (position, label) in order.enumerated() {
            // Black-and-white draws exactly the dark pixels; colour layers also cover the colours drawn after them.
            if isCancelled() { throw CancellationError() }
            var covered = [Bool](repeating: false, count: palette.count)
            for included in (options.colors <= 1 ? [label] : Array(order[position...])) { covered[included] = true }
            let mask = labels.map { $0 >= 0 && covered[$0] }
            let path = try contours(mask, width: pixels.width, height: pixels.height, detail: options.detail,
                                    smooth: options.smooth, minimumArea: minimumArea, scale: scale, isCancelled: isCancelled)
            if !path.isEmpty { layers.append(Layer(color: palette[label], path: path)) }
        }
        return Result(size: size, layers: layers)
    }

    // MARK: SVG

    static func svg(_ result: Result) -> String {
        let width = Int(result.size.width.rounded())
        let height = Int(result.size.height.rounded())
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg" width="\#(width)" height="\#(height)" viewBox="0 0 \#(width) \#(height)">"#,
        ]
        for layer in result.layers {
            lines.append(#"<path fill="\#(layer.color.hex)" fill-rule="evenodd" d="\#(pathData(layer.path))"/>"#)
        }
        lines.append("</svg>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// SVG path data with coordinates to a tenth of a pixel. Numbers are written by hand: a detailed photo has
    /// hundreds of thousands of them, and String(format:) took seconds.
    static func pathData(_ path: CGPath) -> String {
        var text = ""
        text.reserveCapacity(4096)
        func number(_ value: CGFloat) {
            let tenths = Int((value * 10).rounded())
            if tenths < 0 { text.append("-") }
            let magnitude = abs(tenths)
            text.append(String(magnitude / 10))
            if magnitude % 10 != 0 {
                text.append(".")
                text.append(String(magnitude % 10))
            }
        }
        func point(_ p: CGPoint) {
            number(p.x)
            text.append(" ")
            number(p.y)
        }
        path.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint: text.append("M"); point(points[0])
            case .addLineToPoint: text.append("L"); point(points[0])
            case .addQuadCurveToPoint: text.append("Q"); point(points[0]); text.append(" "); point(points[1])
            case .addCurveToPoint:
                text.append("C"); point(points[0]); text.append(" "); point(points[1]); text.append(" "); point(points[2])
            case .closeSubpath: text.append("Z")
            @unknown default: break
            }
        }
        return text
    }

    /// Draws the traced shapes, for the preview.
    static func render(_ result: Result, maxSide: CGFloat) -> CGImage? {
        let scale = min(1, maxSide / max(result.size.width, result.size.height))
        let width = max(1, Int(result.size.width * scale))
        let height = max(1, Int(result.size.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // SVG's y runs down.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        for layer in result.layers {
            context.addPath(layer.path)
            // SVG colours are sRGB.
            context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         components: [layer.color.red, layer.color.green, layer.color.blue, 1])!)
            context.fillPath(using: .evenOdd)
        }
        return context.makeImage()
    }

    // MARK: Contours

    /// Follows every boundary between mask and non-mask pixels. Edges run clockwise around mask pixels (y down), so
    /// at each corner at most two leave; where two do (pixels touching only at a corner) the right turn is taken,
    /// keeping such pixels apart. Points are the middles of the pixel edges, which turns stairs into diagonals.
    private static func contours(_ mask: [Bool], width: Int, height: Int, detail: Double, smooth: Bool,
                                 minimumArea: Double, scale: CGFloat, isCancelled: () -> Bool) throws -> CGPath {
        let stride = width + 1
        // Per corner, the directions of the edges leaving it: 1 right, 2 down, 4 left, 8 up.
        var outgoing = [UInt8](repeating: 0, count: stride * (height + 1))
        func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < width && y < height && mask[y * width + x] }
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                if !inside(x, y - 1) { outgoing[y * stride + x] |= 1 }               // top: (x,y) → right
                if !inside(x + 1, y) { outgoing[y * stride + x + 1] |= 2 }           // right: (x+1,y) → down
                if !inside(x, y + 1) { outgoing[(y + 1) * stride + x + 1] |= 4 }     // bottom: (x+1,y+1) → left
                if !inside(x - 1, y) { outgoing[(y + 1) * stride + x] |= 8 }         // left: (x,y+1) → up
            }
        }
        let steps = [(1, 0), (0, 1), (-1, 0), (0, -1)]
        // Douglas–Peucker tolerance in working pixels: 0.25 at full detail, 1.2 at the lowest. A pixel or more
        // bevelled the corners and slanted the ends of small letters.
        let tolerance = 1.2 - 0.95 * detail
        let path = CGMutablePath()
        for start in outgoing.indices where outgoing[start] != 0 {
            if isCancelled() { throw CancellationError() }
            var points: [CGPoint] = []
            var vertex = start
            var direction = outgoing[start].trailingZeroBitCount
            repeat {
                outgoing[vertex] &= ~(1 << direction)
                let x = vertex % stride, y = vertex / stride
                let step = steps[direction]
                points.append(CGPoint(x: Double(x) + 0.5 * Double(step.0), y: Double(y) + 0.5 * Double(step.1)))
                vertex = (y + step.1) * stride + x + step.0
                let available = outgoing[vertex]
                guard available != 0 else { break }
                let right = (direction + 1) % 4, straight = direction, left = (direction + 3) % 4
                if available & (1 << right) != 0 { direction = right }
                else if available & (1 << straight) != 0 { direction = straight }
                else if available & (1 << left) != 0 { direction = left }
                else { direction = available.trailingZeroBitCount }
            } while true
            guard points.count >= 4, abs(area(points)) >= minimumArea else { continue }
            let simple = sharpenCorners(simplify(points, tolerance: tolerance)).map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
            guard simple.count >= 3 else { continue }
            smooth ? addSmooth(simple, longSegment: 24 * scale, to: path) : addPolygon(simple, to: path)
        }
        return path
    }

    /// Pixels round off a sharp corner, and simplifying keeps that as a short bevel between two straight sides. Where
    /// two longer sides turn by 60° or more across a short segment, the segment is replaced by the point where the
    /// sides meet, so letters and logos get their square corners back.
    static func sharpenCorners(_ points: [CGPoint]) -> [CGPoint] {
        let count = points.count
        guard count >= 5 else { return points }
        func p(_ index: Int) -> CGPoint { points[(index % count + count) % count] }
        func length(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }
        var replaced = [Int: CGPoint]()   // segment start index → corner point
        var index = 0
        while index < count {
            let a = p(index - 1), b = p(index), c = p(index + 1), d = p(index + 2)
            let bevel = length(b, c), before = length(a, b), after = length(c, d)
            // A bevel shares its points with its neighbours; the last one must not take the loop's first point twice.
            let wrapsIntoFirst = index == count - 1 && replaced[0] != nil
            if bevel <= 3, before > bevel * 1.5, after > bevel * 1.5, replaced[index - 1] == nil, !wrapsIntoFirst {
                let u = CGVector(dx: b.x - a.x, dy: b.y - a.y), v = CGVector(dx: d.x - c.x, dy: d.y - c.y)
                let cosine = (u.dx * v.dx + u.dy * v.dy) / (before * after)
                let cross = u.dx * v.dy - u.dy * v.dx
                if cosine < 0.5, abs(cross) > 1e-9 {
                    // Where line a→b meets line c→d.
                    let t = ((c.x - a.x) * v.dy - (c.y - a.y) * v.dx) / cross
                    let corner = CGPoint(x: a.x + u.dx * t, y: a.y + u.dy * t)
                    let middle = CGPoint(x: (b.x + c.x) / 2, y: (b.y + c.y) / 2)
                    if length(corner, middle) <= 3 {
                        replaced[index] = corner
                        index += 2
                        continue
                    }
                }
            }
            index += 1
        }
        guard !replaced.isEmpty else { return points }
        var result: [CGPoint] = []
        var skip = false
        for index in 0..<count {
            if skip { skip = false; continue }
            if let corner = replaced[index] {
                result.append(corner)
                skip = true
            } else if index == 0, let corner = replaced[count - 1] {
                // The bevel wrapped around the end of the loop; its corner is already the last point.
                _ = corner
                continue
            } else {
                result.append(points[index])
            }
        }
        return result.count >= 3 ? result : points
    }

    /// Douglas–Peucker on a closed loop, without recursion: a boundary can have tens of thousands of points.
    static func simplify(_ points: [CGPoint], tolerance: Double) -> [CGPoint] {
        guard points.count > 4 else { return points }
        // Split the loop at the point farthest from the first, then simplify both halves as open lines.
        let first = points[0]
        let far = points.indices.max { hypot(points[$0].x - first.x, points[$0].y - first.y) < hypot(points[$1].x - first.x, points[$1].y - first.y) }!
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[far] = true
        var stack = [(0, far), (far, points.count)]
        while let (from, to) = stack.popLast() {
            let a = points[from], b = points[to % points.count]
            guard to - from > 1 else { continue }
            let dx = b.x - a.x, dy = b.y - a.y
            let length = max(hypot(dx, dy), 1e-9)
            var worst = -1.0, worstIndex = from
            for index in (from + 1)..<to {
                let p = points[index]
                let distance = abs(dy * (p.x - a.x) - dx * (p.y - a.y)) / length
                if distance > worst { worst = distance; worstIndex = index }
            }
            if worst > tolerance {
                keep[worstIndex] = true
                stack.append((from, worstIndex))
                stack.append((worstIndex, to))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    private static func area(_ points: [CGPoint]) -> CGFloat {
        var sum: CGFloat = 0
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    private static func addPolygon(_ points: [CGPoint], to path: CGMutablePath) {
        path.addLines(between: points)
        path.closeSubpath()
    }

    /// Curves only where the outline really bends gently; everything else stays as drawn. A vertex is a corner when
    /// the outline turns there by more than 45°, or by more than 15° next to a long segment (straight edges meet at
    /// corners, curves are made of short steps). Gentle vertices get a quadratic curve between the middles of their
    /// segments, which never leaves the polygon: no bulging diagonals and no loops at corners.
    private static func addSmooth(_ points: [CGPoint], longSegment: CGFloat, to path: CGMutablePath) {
        let count = points.count
        func p(_ index: Int) -> CGPoint { points[(index % count + count) % count] }
        func middle(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        let corner: [Bool] = (0..<count).map { index in
            let a = p(index - 1), b = p(index), c = p(index + 1)
            let v1 = CGVector(dx: b.x - a.x, dy: b.y - a.y), v2 = CGVector(dx: c.x - b.x, dy: c.y - b.y)
            let l1 = hypot(v1.dx, v1.dy), l2 = hypot(v2.dx, v2.dy)
            guard l1 > 0, l2 > 0 else { return true }
            let cosine = (v1.dx * v2.dx + v1.dy * v2.dy) / (l1 * l2)
            // Sharper than 45° is always a corner; 15–45° only next to a long straight segment.
            let nearStraight = l1 > longSegment || l2 > longSegment
            return cosine < 0.707 || (nearStraight && cosine < 0.966)
        }
        path.move(to: corner[0] ? p(0) : middle(p(-1), p(0)))
        for index in 1...count {
            let vertex = p(index)
            if corner[index % count] {
                path.addLine(to: vertex)
            } else {
                let start = middle(p(index - 1), vertex)
                if path.currentPoint != start { path.addLine(to: start) }
                path.addQuadCurve(to: middle(vertex, p(index + 1)), control: vertex)
            }
        }
        path.closeSubpath()
    }

    /// The colour most common along the picture's border.
    private static func edgeColor(_ labels: [Int], width: Int, height: Int) -> Int? {
        var counts: [Int: Int] = [:]
        for x in 0..<width {
            counts[labels[x], default: 0] += 1
            counts[labels[(height - 1) * width + x], default: 0] += 1
        }
        for y in 0..<height {
            counts[labels[y * width], default: 0] += 1
            counts[labels[y * width + width - 1], default: 0] += 1
        }
        counts[-1] = nil
        return counts.max { $0.value < $1.value }?.key
    }

    // MARK: Colours

    /// Otsu's threshold on luminance: the split that best separates dark ink from light paper.
    static func otsuThreshold(_ pixels: Pixels) -> Double {
        var histogram = [Double](repeating: 0, count: 256)
        var total = 0.0
        for index in 0..<pixels.count {
            histogram[min(255, Int(pixels.luminanceOnWhite(index) * 255))] += 1
            total += 1
        }
        guard total > 0 else { return 0.5 }
        let sum = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset) * $1.element }
        var backgroundWeight = 0.0, backgroundSum = 0.0, best = 0.0, threshold = 127
        for level in 0..<256 {
            backgroundWeight += histogram[level]
            guard backgroundWeight > 0 else { continue }
            let foregroundWeight = total - backgroundWeight
            if foregroundWeight == 0 { break }
            backgroundSum += Double(level) * histogram[level]
            let meanB = backgroundSum / backgroundWeight
            let meanF = (sum - backgroundSum) / foregroundWeight
            let between = backgroundWeight * foregroundWeight * (meanB - meanF) * (meanB - meanF)
            if between > best { best = between; threshold = level }
        }
        return (Double(threshold) + 0.5) / 255
    }

    /// k-means on a sample of the opaque pixels, seeded deterministically with the farthest points; then every
    /// pixel takes its nearest colour.
    static func quantize(_ pixels: Pixels, colors: Int) -> (palette: [RGB], labels: [Int]) {
        let opaque = (0..<pixels.count).filter { pixels.alpha($0) >= 0.5 }
        guard !opaque.isEmpty else { return ([], [Int](repeating: -1, count: pixels.count)) }
        let step = max(1, opaque.count / 20_000)
        let sample = stride(from: 0, to: opaque.count, by: step).map { pixels.rgb(opaque[$0]) }
        func distance(_ a: RGB, _ b: RGB) -> Double {
            let dr = a.red - b.red, dg = a.green - b.green, db = a.blue - b.blue
            return dr * dr * 0.3 + dg * dg * 0.59 + db * db * 0.11
        }
        var centers = [sample[0]]
        var nearestDistance = sample.map { distance($0, sample[0]) }
        while centers.count < colors {
            guard let farthest = nearestDistance.indices.max(by: { nearestDistance[$0] < nearestDistance[$1] }),
                  nearestDistance[farthest] > 1e-6 else { break }
            centers.append(sample[farthest])
            for index in sample.indices { nearestDistance[index] = min(nearestDistance[index], distance(sample[index], sample[farthest])) }
        }
        func nearest(_ color: RGB) -> Int {
            var best = 0, bestDistance = Double.infinity
            for (index, center) in centers.enumerated() {
                let d = distance(center, color)
                if d < bestDistance { bestDistance = d; best = index }
            }
            return best
        }
        for _ in 0..<12 {
            var sums = [(Double, Double, Double, Double)](repeating: (0, 0, 0, 0), count: centers.count)
            for color in sample {
                let index = nearest(color)
                sums[index].0 += color.red; sums[index].1 += color.green; sums[index].2 += color.blue; sums[index].3 += 1
            }
            var moved = false
            for index in centers.indices where sums[index].3 > 0 {
                let updated = RGB(red: sums[index].0 / sums[index].3, green: sums[index].1 / sums[index].3,
                                  blue: sums[index].2 / sums[index].3)
                if distance(updated, centers[index]) > 1e-7 { moved = true }
                centers[index] = updated
            }
            if !moved { break }
        }
        // Anti-aliased edges pull a colour towards its neighbours; the final colour is the mean of the half of its
        // pixels closest to the centre, so a red logo stays red rather than pink.
        var members = [[RGB]](repeating: [], count: centers.count)
        for color in sample { members[nearest(color)].append(color) }
        for index in centers.indices where !members[index].isEmpty {
            let core = members[index].sorted { distance($0, centers[index]) < distance($1, centers[index]) }
                .prefix(max(1, members[index].count / 2))
            let count = Double(core.count)
            centers[index] = RGB(red: core.map(\.red).reduce(0, +) / count, green: core.map(\.green).reduce(0, +) / count,
                                 blue: core.map(\.blue).reduce(0, +) / count)
        }
        // Colours too close to tell apart become one: a one-colour logo asked for two colours gave two blacks.
        var representative = Array(centers.indices)
        for index in centers.indices {
            if let earlier = (0..<index).first(where: { representative[$0] == $0 && distance(centers[$0], centers[index]) < 0.0015 }) {
                representative[index] = earlier
            }
        }
        let labels = (0..<pixels.count).map { pixels.alpha($0) >= 0.5 ? representative[nearest(pixels.rgb($0))] : -1 }
        return (centers, labels)
    }

    // MARK: Pixels

    /// The picture as 8-bit RGBA, downscaled to `maxSide`, with transparency kept.
    struct Pixels {
        let width: Int
        let height: Int
        private let bytes: [UInt8]
        var count: Int { width * height }

        init(_ image: CGImage, maxSide: Int) throws {
            let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
            width = max(1, Int((Double(image.width) * scale).rounded()))
            height = max(1, Int((Double(image.height) * scale).rounded()))
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let (w, h) = (width, height)
            let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
                guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                              bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { throw ConversionError.encodeFailed(.svg) }
            bytes = buffer
        }

        func alpha(_ index: Int) -> Double { Double(bytes[index * 4 + 3]) / 255 }

        /// Un-premultiplied colour.
        func rgb(_ index: Int) -> RGB {
            let a = max(Double(bytes[index * 4 + 3]), 1)
            return RGB(red: min(1, Double(bytes[index * 4]) / a), green: min(1, Double(bytes[index * 4 + 1]) / a),
                       blue: min(1, Double(bytes[index * 4 + 2]) / a))
        }

        func luminance(_ index: Int) -> Double {
            let color = rgb(index)
            return 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
        }

        /// The luminance as seen on white paper: transparent pixels are white, half-transparent ones lighter.
        func luminanceOnWhite(_ index: Int) -> Double {
            let a = alpha(index)
            return luminance(index) * a + (1 - a)
        }
    }

    // MARK: Files

    /// Traces `input` and writes "<name>.svg".
    static func traceFile(_ input: URL, options: Options) throws -> URL {
        let (image, _) = try ImageConverter.load(input, maxPixelSize: 4096)
        let result = try trace(image, options: options)
        let text = svg(result)
        return try OutputNaming.writeAtomically(directory: input.deletingLastPathComponent(),
                                                baseName: OutputNaming.baseName(of: input), pathExtension: "svg") {
            try text.write(to: $0, atomically: false, encoding: .utf8)
        }
    }
}

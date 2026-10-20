import SwiftUI

/// The crop editor shared by image and video cropping: the picture, a dimmed outside area, a rule-of-thirds
/// frame that can be dragged, and eight resize handles. `rect` is normalised (0…1, top-left origin);
/// `aspect` (width / height in normalised units) locks the proportions when set.
struct CropCanvas: View {
    let image: CGImage?
    let imageSize: CGSize
    @Binding var rect: CGRect
    let aspect: CGFloat?
    var message: String?
    /// Split lines inside the frame as fractions of its width and height; they can be dragged.
    /// Without any, the rule of thirds is shown.
    var columnCuts: Binding<[CGFloat]>?
    var rowCuts: Binding<[CGFloat]>?

    @State private var dragStart: CGRect?
    @State private var cutDragStart: CGFloat?

    private var hasCuts: Bool { !(columnCuts?.wrappedValue.isEmpty ?? true) || !(rowCuts?.wrappedValue.isEmpty ?? true) }

    var body: some View {
        GeometryReader { geometry in
            let frame = fittedFrame(in: geometry.size)
            let crop = CGRect(x: frame.minX + rect.minX * frame.width, y: frame.minY + rect.minY * frame.height,
                              width: rect.width * frame.width, height: rect.height * frame.height)
            ZStack(alignment: .topLeading) {
                Color.clear
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)

                    Path { path in
                        path.addRect(frame)
                        path.addRect(crop)
                    }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

                    if hasCuts {
                        grid(crop)
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    } else {
                        thirds(crop)
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                    }
                    Path { $0.addRect(crop) }
                        .stroke(Color.white, lineWidth: 1.5)

                    Rectangle()
                        .fill(Color.white.opacity(0.001))
                        .frame(width: crop.width, height: crop.height)
                        .position(x: crop.midX, y: crop.midY)
                        .gesture(moveGesture(frame))

                    if let columnCuts {
                        ForEach(columnCuts.wrappedValue.indices, id: \.self) { index in
                            Rectangle()
                                .fill(Color.white.opacity(0.001))
                                .frame(width: 10, height: crop.height)
                                .position(x: crop.minX + crop.width * columnCuts.wrappedValue[index], y: crop.midY)
                                .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                                .gesture(cutGesture(columnCuts, index: index, length: crop.width, vertical: false))
                        }
                    }
                    if let rowCuts {
                        ForEach(rowCuts.wrappedValue.indices, id: \.self) { index in
                            Rectangle()
                                .fill(Color.white.opacity(0.001))
                                .frame(width: crop.width, height: 10)
                                .position(x: crop.midX, y: crop.minY + crop.height * rowCuts.wrappedValue[index])
                                .onHover { inside in inside ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
                                .gesture(cutGesture(rowCuts, index: index, length: crop.height, vertical: true))
                        }
                    }

                    ForEach(ImageCropper.Handle.allCases, id: \.self) { handle in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white)
                            .frame(width: 12, height: 12)
                            .shadow(radius: 1)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                            .position(handle.point(in: crop))
                            .gesture(resizeGesture(handle, frame: frame))
                    }
                } else if let message {
                    Text(message).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func fittedFrame(in container: CGSize) -> CGRect {
        let inset: CGFloat = 16
        let available = CGSize(width: max(container.width - inset * 2, 1), height: max(container.height - inset * 2, 1))
        let scale = min(available.width / max(imageSize.width, 1), available.height / max(imageSize.height, 1))
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func grid(_ crop: CGRect) -> Path {
        Path { path in
            for cut in columnCuts?.wrappedValue ?? [] {
                let x = crop.minX + crop.width * cut
                path.move(to: CGPoint(x: x, y: crop.minY))
                path.addLine(to: CGPoint(x: x, y: crop.maxY))
            }
            for cut in rowCuts?.wrappedValue ?? [] {
                let y = crop.minY + crop.height * cut
                path.move(to: CGPoint(x: crop.minX, y: y))
                path.addLine(to: CGPoint(x: crop.maxX, y: y))
            }
        }
    }

    /// Moves one cut line, keeping it between its neighbours (and the frame edges) with a small gap.
    private func cutGesture(_ cuts: Binding<[CGFloat]>, index: Int, length: CGFloat, vertical: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard cuts.wrappedValue.indices.contains(index), length > 0 else { return }
                let start = cutDragStart ?? cuts.wrappedValue[index]
                cutDragStart = start
                let gap: CGFloat = 0.03
                let lower = (index > 0 ? cuts.wrappedValue[index - 1] : 0) + gap
                let upper = (index < cuts.wrappedValue.count - 1 ? cuts.wrappedValue[index + 1] : 1) - gap
                let moved = start + (vertical ? value.translation.height : value.translation.width) / length
                cuts.wrappedValue[index] = min(max(moved, lower), max(lower, upper))
            }
            .onEnded { _ in cutDragStart = nil }
    }

    private func thirds(_ crop: CGRect) -> Path {
        Path { path in
            for fraction in [1.0 / 3, 2.0 / 3] {
                path.move(to: CGPoint(x: crop.minX + crop.width * fraction, y: crop.minY))
                path.addLine(to: CGPoint(x: crop.minX + crop.width * fraction, y: crop.maxY))
                path.move(to: CGPoint(x: crop.minX, y: crop.minY + crop.height * fraction))
                path.addLine(to: CGPoint(x: crop.maxX, y: crop.minY + crop.height * fraction))
            }
        }
    }

    private func moveGesture(_ frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? rect
                dragStart = start
                var moved = start
                moved.origin.x = min(max(start.minX + value.translation.width / frame.width, 0), 1 - start.width)
                moved.origin.y = min(max(start.minY + value.translation.height / frame.height, 0), 1 - start.height)
                rect = moved
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ handle: ImageCropper.Handle, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? rect
                dragStart = start
                if let resized = ImageCropper.resize(start, handle: handle,
                                                     dx: value.translation.width / frame.width,
                                                     dy: value.translation.height / frame.height,
                                                     aspect: aspect) {
                    rect = resized
                }
            }
            .onEnded { _ in dragStart = nil }
    }
}

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

    @State private var dragStart: CGRect?

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

                    thirds(crop)
                        .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                    Path { $0.addRect(crop) }
                        .stroke(Color.white, lineWidth: 1.5)

                    Rectangle()
                        .fill(Color.white.opacity(0.001))
                        .frame(width: crop.width, height: crop.height)
                        .position(x: crop.midX, y: crop.midY)
                        .gesture(moveGesture(frame))

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

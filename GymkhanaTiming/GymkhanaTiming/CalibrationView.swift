import SwiftUI
import AVFoundation

/// Разметка линии старта-финиша по двум точкам на кадре видео.
/// Как и в python-версии: точки нужно ставить по самой покрасочной/меловой
/// линии на асфальте, а не по основанию конусов — иначе получится
/// систематическая ошибка в доли секунды.
struct CalibrationView: View {
    let videoURL: URL
    let onCalibrated: (CGPoint, CGPoint) -> Void

    @State private var frameImage: UIImage?
    @State private var pixelSize: CGSize = .zero
    @State private var points: [CGPoint] = [] // в пиксельных координатах кадра
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            Text("Отметьте две точки на линии старта-финиша (по разметке на асфальте)")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            GeometryReader { geo in
                if let frameImage {
                    ZStack {
                        Image(uiImage: frameImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onEnded { value in
                                        addPoint(at: value.location, containerSize: geo.size)
                                    }
                            )

                        ForEach(Array(markerPositions(containerSize: geo.size).enumerated()), id: \.offset) { _, pos in
                            Circle()
                                .fill(Color.red)
                                .frame(width: 12, height: 12)
                                .position(pos)
                        }

                        if markerPositions(containerSize: geo.size).count == 2 {
                            let pts = markerPositions(containerSize: geo.size)
                            Path { path in
                                path.move(to: pts[0])
                                path.addLine(to: pts[1])
                            }
                            .stroke(Color.red, lineWidth: 2)
                        }
                    }
                } else {
                    ProgressView()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .padding()

            if let errorMessage {
                Text(errorMessage).foregroundColor(.red)
            }

            HStack {
                Button("Сбросить") { points.removeAll() }
                    .disabled(points.isEmpty)
                Spacer()
                Button("Далее") {
                    if points.count == 2 {
                        onCalibrated(points[0], points[1])
                    }
                }
                .disabled(points.count != 2)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
        }
        .task { await loadFrame() }
    }

    private func addPoint(at location: CGPoint, containerSize: CGSize) {
        guard points.count < 2, pixelSize != .zero else { return }
        guard let pixelPoint = displayPointToPixel(location, containerSize: containerSize) else { return }
        points.append(pixelPoint)
    }

    /// Переводит точку тапа (в координатах контейнера с .scaledToFit)
    /// в пиксельные координаты исходного кадра.
    private func displayPointToFrame(_ imageSize: CGSize, containerSize: CGSize) -> CGRect {
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let displayedWidth = imageSize.width * scale
        let displayedHeight = imageSize.height * scale
        let originX = (containerSize.width - displayedWidth) / 2
        let originY = (containerSize.height - displayedHeight) / 2
        return CGRect(x: originX, y: originY, width: displayedWidth, height: displayedHeight)
    }

    private func displayPointToPixel(_ point: CGPoint, containerSize: CGSize) -> CGPoint? {
        let frame = displayPointToFrame(pixelSize, containerSize: containerSize)
        guard frame.contains(point) else { return nil }
        let relX = (point.x - frame.origin.x) / frame.width
        let relY = (point.y - frame.origin.y) / frame.height
        return CGPoint(x: relX * pixelSize.width, y: relY * pixelSize.height)
    }

    private func markerPositions(containerSize: CGSize) -> [CGPoint] {
        guard pixelSize != .zero else { return [] }
        let frame = displayPointToFrame(pixelSize, containerSize: containerSize)
        return points.map { p in
            CGPoint(
                x: frame.origin.x + (p.x / pixelSize.width) * frame.width,
                y: frame.origin.y + (p.y / pixelSize.height) * frame.height
            )
        }
    }

    private func loadFrame() async {
        let asset = AVURLAsset(url: videoURL)
        do {
            let duration = try await asset.load(.duration)
            let time = CMTime(seconds: min(0.5, duration.seconds / 2), preferredTimescale: 600)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
            frameImage = UIImage(cgImage: cgImage)
            pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        } catch {
            errorMessage = "Не удалось получить кадр: \(error.localizedDescription)"
        }
    }
}

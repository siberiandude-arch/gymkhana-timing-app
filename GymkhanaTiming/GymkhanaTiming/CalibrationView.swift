import SwiftUI
import AVFoundation

/// Разметка линии старта-финиша по двум точкам на кадре видео.
/// Как и в python-версии: точки нужно ставить по самой покрасочной/меловой
/// линии на асфальте, а не по основанию конусов — иначе получится
/// систематическая ошибка в доли секунды.
struct CalibrationView: View {
    let videoURL: URL
    let onBack: () -> Void
    let onCalibrated: (CGPoint, CGPoint) -> Void

    @State private var frameImage: UIImage?
    @State private var pixelSize: CGSize = .zero
    @State private var points: [CGPoint] = [] // в пиксельных координатах кадра
    @State private var errorMessage: String?
    @State private var videoDuration: Double = 0
    @State private var frameTime: Double = 0
    @State private var isLoadingFrame = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(RoundIconButtonStyle())
                Spacer()
            }
            .padding(.horizontal)

            Text("Отметьте две точки на линии старта-финиша (по разметке на асфальте)")
                .font(.footnote)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            GeometryReader { geo in
                ZStack {
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

                    if isLoadingFrame {
                        Color.black.opacity(0.3)
                        ProgressView()
                    }
                }
            }
            .padding()

            // Мотоцикл в кадре на выбранный момент иногда закрывает собой
            // конусы/линию — ползунок даёт найти кадр, где разметка видна
            // целиком, вместо одного фиксированного кадра на всё видео.
            if videoDuration > 0 {
                VStack(spacing: 2) {
                    Slider(
                        value: Binding(
                            get: { frameTime },
                            set: { frameTime = $0 }
                        ),
                        in: 0...videoDuration,
                        onEditingChanged: { editing in
                            if !editing { Task { await loadFrame(at: frameTime) } }
                        }
                    )
                    .tint(AppTheme.accent)
                    Text(String(format: "Кадр на %.1fс из %.1fс — подвиньте, если конусы не видно", frameTime, videoDuration))
                        .font(.caption2)
                        .foregroundColor(AppTheme.textSecondary)
                }
                .padding(.horizontal)
            }

            if let errorMessage {
                Text(errorMessage).foregroundColor(.red)
            }

            HStack {
                Button("Сбросить точки") { points.removeAll() }
                    .foregroundColor(.white)
                    .disabled(points.isEmpty)
                Spacer()
            }
            .padding(.horizontal)

            Button {
                if points.count == 2 {
                    onCalibrated(points[0], points[1])
                }
            } label: {
                Text(points.count == 2 ? "Далее" : "Отметьте 2 точки (\(points.count)/2)")
            }
            .disabled(points.count != 2)
            .buttonStyle(PrimaryButtonStyle(tint: points.count == 2 ? AppTheme.accent : AppTheme.surface))
            .padding(.horizontal)
            .padding(.bottom)
        }
        .appBackground()
        .task {
            await loadDuration()
            await loadFrame(at: frameTime)
        }
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

    private func loadDuration() async {
        let asset = AVURLAsset(url: videoURL)
        if let duration = try? await asset.load(.duration) {
            videoDuration = duration.seconds
            frameTime = min(0.5, videoDuration / 2)
        }
    }

    private func loadFrame(at time: Double) async {
        isLoadingFrame = true
        defer { isLoadingFrame = false }
        let asset = AVURLAsset(url: videoURL)
        do {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            let cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)
            frameImage = UIImage(cgImage: cgImage)
            pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
            errorMessage = nil
        } catch {
            errorMessage = "Не удалось получить кадр: \(error.localizedDescription)"
        }
    }
}

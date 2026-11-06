import SwiftUI
import AVFoundation

/// Разметка линии старта-финиша: пользователь одним движением пальца
/// обводит два стартовых конуса (контур сам замыкается, если не доведён до
/// начала) — ConeDetector находит основания конусов по цвету, и между ними
/// проводится линия. Ручной постановки точек нет: попасть пальцем в
/// основание конуса точно не получается, а детектор делает это стабильнее.
struct CalibrationView: View {
    let videoURL: URL
    let onBack: () -> Void
    let onCalibrated: (CGPoint, CGPoint) -> Void

    @State private var frameImage: UIImage?
    @State private var frameCGImage: CGImage?
    @State private var pixelSize: CGSize = .zero
    @State private var points: [CGPoint] = [] // в пиксельных координатах кадра
    @State private var errorMessage: String?
    @State private var videoDuration: Double = 0
    @State private var frameTime: Double = 0
    @State private var isLoadingFrame = false
    @State private var lasso: [CGPoint] = [] // в координатах контейнера
    @State private var isPinching = false
    @State private var isDrawing = false
    @State private var isDetecting = false
    @State private var zoomScale: CGFloat = 1

    var body: some View {
        GeometryReader { root in
            if root.size.width > root.size.height {
                // Альбомная: кадр на всю высоту слева, управление справа —
                // так картинка получается максимально крупной.
                HStack(alignment: .top, spacing: 12) {
                    frameArea
                    controls
                        .frame(width: min(230, root.size.width * 0.3))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 8) {
                    frameArea
                    controls
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .appBackground()
        .task {
            await loadDuration()
            await loadFrame(at: frameTime)
        }
    }

    private var frameArea: some View {
        GeometryReader { geo in
            ZStack {
                if let frameImage {
                    ZStack {
                        Image(uiImage: frameImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)

                        ForEach(Array(markerPositions(containerSize: geo.size).enumerated()), id: \.offset) { _, pos in
                            Circle()
                                .fill(Color.red)
                                .frame(width: 12, height: 12)
                                .position(pos)
                                .allowsHitTesting(false)
                        }

                        if markerPositions(containerSize: geo.size).count == 2 {
                            let pts = markerPositions(containerSize: geo.size)
                            Path { path in
                                path.move(to: pts[0])
                                path.addLine(to: pts[1])
                            }
                            .stroke(Color.red, lineWidth: 2)
                            .allowsHitTesting(false)
                        }

                        if lasso.count > 1 {
                            Path { path in
                                path.move(to: lasso[0])
                                for pt in lasso.dropFirst() { path.addLine(to: pt) }
                            }
                            .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                            .allowsHitTesting(false)

                            // Пунктир замыкания: куда контур сам дотянется
                            Path { path in
                                path.move(to: lasso[lasso.count - 1])
                                path.addLine(to: lasso[0])
                            }
                            .stroke(AppTheme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                            .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 10)
                            .onChanged { value in handleDrag(value, containerSize: geo.size, ended: false) }
                            .onEnded { value in handleDrag(value, containerSize: geo.size, ended: true) }
                    )
                    .scaleEffect(zoomScale, anchor: .center)
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                isPinching = true
                                lasso.removeAll()
                                zoomScale = min(4, max(1, value))
                            }
                            .onEnded { _ in isPinching = false }
                    )
                } else {
                    ProgressView()
                        .frame(width: geo.size.width, height: geo.size.height)
                }

                if isLoadingFrame || isDetecting {
                    Color.black.opacity(0.3)
                        .allowsHitTesting(false)
                    ProgressView(isDetecting ? "Ищу конусы..." : "")
                        .tint(AppTheme.accent)
                        .foregroundColor(.white)
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(RoundIconButtonStyle())

                Spacer()

                if zoomScale != 1 {
                    Button("100%") { zoomScale = 1 }
                        .buttonStyle(.bordered)
                }
            }

            Text(modeHint)
                .font(.caption)
                .foregroundColor(.white)

            if videoDuration > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    Slider(
                        value: Binding(get: { frameTime }, set: { frameTime = $0 }),
                        in: 0...videoDuration,
                        onEditingChanged: { editing in
                            if !editing { Task { await loadFrame(at: frameTime) } }
                        }
                    )
                    .tint(AppTheme.accent)
                    Text(String(format: "Кадр %.1f из %.1f с. Если конусов не видно — подвиньте", frameTime, videoDuration))
                        .font(.caption2)
                        .foregroundColor(AppTheme.textSecondary)
                }
            }

            if let errorMessage {
                Text(errorMessage).foregroundColor(.red).font(.footnote)
            }

            Spacer(minLength: 0)

            Button("Обвести заново") { points.removeAll(); lasso.removeAll(); errorMessage = nil }
                .buttonStyle(CompactButtonStyle())
                .disabled(points.isEmpty && lasso.isEmpty)

            Button {
                if points.count == 2 { onCalibrated(points[0], points[1]) }
            } label: {
                Text(points.count == 2 ? "Далее" : "Обведите конусы")
            }
            .disabled(points.count != 2)
            .buttonStyle(PrimaryButtonStyle(tint: points.count == 2 ? AppTheme.accent : AppTheme.surface))
        }
    }

    private var modeHint: String {
        "Обведите пальцем оба стартовых конуса — контур замкнётся сам. Линия пройдёт по основаниям конусов."
    }

    private func handleDrag(_ value: DragGesture.Value, containerSize: CGSize, ended: Bool) {
        let wasDrawing = isDrawing
        isDrawing = !ended
        // Когда линия уже построена, жесты на кадре ничего не сбрасывают —
        // случайный тап (особенно при масштабировании) не должен стирать
        // результат. Чтобы обвести заново, есть кнопка «Обвести заново».
        guard points.count < 2, !isPinching, !isDetecting else { return }
        if !wasDrawing {
            lasso = [value.startLocation]
            points.removeAll()
            errorMessage = nil
        }
        if let last = lasso.last, hypot(last.x - value.location.x, last.y - value.location.y) >= 3 {
            lasso.append(value.location)
        }
        if ended {
            finishLasso(containerSize: containerSize)
        }
    }

    private func finishLasso(containerSize: CGSize) {
        guard lasso.count >= 8 else {
            lasso.removeAll()
            errorMessage = "Слишком короткая линия — обведите оба конуса одним движением"
            return
        }
        guard let frameCGImage else { return }
        let pixelPolygon = lasso.compactMap { displayPointToPixel($0, containerSize: containerSize, clamped: true) }
        guard pixelPolygon.count >= 3 else {
            lasso.removeAll()
            errorMessage = "Обводка вышла за пределы кадра — попробуйте ещё раз"
            return
        }
        isDetecting = true
        errorMessage = nil
        Task {
            defer { isDetecting = false }
            do {
                let (left, right) = try ConeDetector.findConeBases(in: frameCGImage, polygon: pixelPolygon)
                await MainActor.run {
                    points = [left, right]
                    lasso.removeAll()
                    errorMessage = nil
                }
            } catch {
                await MainActor.run {
                    lasso.removeAll()
                    errorMessage = "Не нашёл 2 конуса внутри контура — обведите точнее (оба конуса должны быть целиком внутри) или выберите другой кадр ползунком"
                }
            }
        }
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

    private func displayPointToPixel(_ point: CGPoint, containerSize: CGSize, clamped: Bool = false) -> CGPoint? {
        let frame = displayPointToFrame(pixelSize, containerSize: containerSize)
        var point = point
        if clamped {
            point.x = min(max(point.x, frame.minX), frame.maxX)
            point.y = min(max(point.y, frame.minY), frame.maxY)
        }
        guard clamped || frame.contains(point) else { return nil }
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
            frameCGImage = cgImage
            pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
            errorMessage = nil
            lasso.removeAll()
        } catch {
            errorMessage = "Не удалось получить кадр: \(error.localizedDescription)"
        }
    }
}

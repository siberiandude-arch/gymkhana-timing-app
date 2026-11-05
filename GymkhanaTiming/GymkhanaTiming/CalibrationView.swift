import SwiftUI
import AVFoundation

/// Разметка линии старта-финиша: либо тапнуть две точки по разметке на
/// асфальте вручную, либо обвести прямоугольником область со стартовыми
/// конусами — тогда ConeDetector сам найдёт их основания по цвету.
/// В обоих случаях итог — те же две точки `points`, использующиеся дальше
/// одинаково.
struct CalibrationView: View {
    let videoURL: URL
    let onBack: () -> Void
    let onCalibrated: (CGPoint, CGPoint) -> Void

    private enum Mode: String, CaseIterable {
        case manual = "Тапнуть точки"
        case autoDetect = "Обвести конусы"
    }

    @State private var frameImage: UIImage?
    @State private var frameCGImage: CGImage?
    @State private var pixelSize: CGSize = .zero
    @State private var points: [CGPoint] = [] // в пиксельных координатах кадра
    @State private var errorMessage: String?
    @State private var videoDuration: Double = 0
    @State private var frameTime: Double = 0
    @State private var isLoadingFrame = false
    @State private var mode: Mode = .manual
    @State private var selectionStart: CGPoint?
    @State private var selectionEnd: CGPoint?
    @State private var isDetecting = false
    @State private var zoomScale: CGFloat = 1
    @State private var lastContainerSize: CGSize = .zero

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(RoundIconButtonStyle())

                Picker("Режим", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                if zoomScale != 1 {
                    Button("100%") { zoomScale = 1 }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            Text(modeHint)
                .font(.caption)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .lineLimit(2)

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
                                        .onChanged { value in handleDrag(value, containerSize: geo.size, ended: false) }
                                        .onEnded { value in handleDrag(value, containerSize: geo.size, ended: true) }
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

                            if mode == .autoDetect, let a = selectionStart, let b = selectionEnd {
                                let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                                   width: abs(a.x - b.x), height: abs(a.y - b.y))
                                Rectangle()
                                    .strokeBorder(AppTheme.accent, lineWidth: 2)
                                    .background(Rectangle().fill(AppTheme.accent.opacity(0.15)))
                                    .frame(width: rect.width, height: rect.height)
                                    .position(x: rect.midX, y: rect.midY)
                            }
                        }
                        .scaleEffect(zoomScale, anchor: .center)
                        .simultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in zoomScale = min(4, max(1, value)) }
                        )
                    } else {
                        ProgressView()
                            .frame(width: geo.size.width, height: geo.size.height)
                    }

                    if isLoadingFrame || isDetecting {
                        Color.black.opacity(0.3)
                        ProgressView(isDetecting ? "Ищу конусы..." : "")
                            .tint(AppTheme.accent)
                            .foregroundColor(.white)
                    }
                }
            }
            .padding(.horizontal)

            if videoDuration > 0 {
                VStack(spacing: 2) {
                    Slider(
                        value: Binding(get: { frameTime }, set: { frameTime = $0 }),
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
                Text(errorMessage).foregroundColor(.red).font(.footnote).padding(.horizontal)
            }

            HStack(spacing: 10) {
                Button("Сбросить") { points.removeAll(); selectionStart = nil; selectionEnd = nil }
                    .foregroundColor(.white)
                    .disabled(points.isEmpty && selectionStart == nil)

                if mode == .autoDetect {
                    Button("Найти конусы") { detectConesInSelection(containerSize: lastContainerSize) }
                        .buttonStyle(.bordered)
                        .disabled(selectionStart == nil || selectionEnd == nil || isDetecting)
                }

                Spacer()
            }
            .padding(.horizontal)

            Button {
                if points.count == 2 { onCalibrated(points[0], points[1]) }
            } label: {
                Text(points.count == 2 ? "Далее" : "Отметьте 2 точки (\(points.count)/2)")
            }
            .disabled(points.count != 2)
            .buttonStyle(PrimaryButtonStyle(tint: points.count == 2 ? AppTheme.accent : AppTheme.surface))
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
        .appBackground()
        .task {
            await loadDuration()
            await loadFrame(at: frameTime)
        }
    }

    private var modeHint: String {
        switch mode {
        case .manual:
            return "Тапните 2 точки у ОСНОВАНИЯ конусов (на асфальте), не по телу конуса"
        case .autoDetect:
            return "Проведите пальцем прямоугольник вокруг обоих стартовых конусов, потом «Найти конусы»"
        }
    }

    private func handleDrag(_ value: DragGesture.Value, containerSize: CGSize, ended: Bool) {
        lastContainerSize = containerSize
        switch mode {
        case .manual:
            guard ended else { return }
            addPoint(at: value.location, containerSize: containerSize)
        case .autoDetect:
            if selectionStart == nil { selectionStart = value.startLocation }
            selectionEnd = value.location
        }
    }

    private func addPoint(at location: CGPoint, containerSize: CGSize) {
        guard points.count < 2, pixelSize != .zero else { return }
        guard let pixelPoint = displayPointToPixel(location, containerSize: containerSize) else { return }
        points.append(pixelPoint)
    }

    private func detectConesInSelection(containerSize: CGSize) {
        guard let frameCGImage, let a = selectionStart, let b = selectionEnd else { return }
        guard let p1 = displayPointToPixel(a, containerSize: containerSize),
              let p2 = displayPointToPixel(b, containerSize: containerSize) else {
            errorMessage = "Выделение вышло за пределы кадра — обведите конусы ещё раз"
            return
        }
        isDetecting = true
        errorMessage = nil
        let region = CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y),
                             width: abs(p1.x - p2.x), height: abs(p1.y - p2.y))
        Task {
            defer { isDetecting = false }
            do {
                let (left, right) = try ConeDetector.findConeBases(in: frameCGImage, region: region)
                await MainActor.run {
                    points = [left, right]
                    selectionStart = nil
                    selectionEnd = nil
                    errorMessage = nil
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Не нашёл 2 конуса в выделении — попробуйте точнее обвести, или переключитесь на ручную разметку"
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
            frameCGImage = cgImage
            pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
            errorMessage = nil
        } catch {
            errorMessage = "Не удалось получить кадр: \(error.localizedDescription)"
        }
    }
}

import SwiftUI
import AVFoundation

struct ResultView: View {
    let result: AnalysisResult
    let videoURL: URL
    let p1: CGPoint
    let p2: CGPoint
    let onRestart: () -> Void

    @State private var startImage: UIImage?
    @State private var finishImage: UIImage?
    @State private var snapshotError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text(String(format: "%.3f с", result.lap))
                    .font(.system(size: 48, weight: .bold, design: .monospaced))

                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "старт:  %.3f с", result.start))
                    Text(String(format: "финиш: %.3f с", result.finish))
                    Text("пересечений линии всего: \(result.crossings.count)")
                }
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)

                // Кадры старта/финиша с прочерченной калибровочной линией —
                // чтобы можно было на глаз проверить, что линия стоит там же,
                // где её разметили, и что алгоритм поймал реальный момент
                // пересечения, а не что-то случайное.
                HStack(alignment: .top, spacing: 12) {
                    snapshotTile(title: "Старт", image: startImage)
                    snapshotTile(title: "Финиш", image: finishImage)
                }

                if let snapshotError {
                    Text(snapshotError)
                        .foregroundColor(.red)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }

                Button("Новый заезд", action: onRestart)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 12)
            }
            .padding()
        }
        .task { await loadSnapshots() }
    }

    @ViewBuilder
    private func snapshotTile(title: String, image: UIImage?) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 160)
                    .cornerRadius(6)
            } else {
                ProgressView()
                    .frame(width: 160, height: 90)
            }
        }
    }

    private func loadSnapshots() async {
        async let start = Self.annotatedFrame(videoURL: videoURL, time: result.start, p1: p1, p2: p2)
        async let finish = Self.annotatedFrame(videoURL: videoURL, time: result.finish, p1: p1, p2: p2)
        let (startResult, finishResult) = await (start, finish)
        if startResult == nil, finishResult == nil {
            snapshotError = "Не удалось извлечь кадры старта/финиша из видео"
        }
        startImage = startResult
        finishImage = finishResult
    }

    /// Достаёт кадр видео на заданной секунде и прочерчивает на нём
    /// калибровочную линию (p1→p2) — те же координаты, что ставились в
    /// CalibrationView и что использовал VideoAnalyzer при расчёте.
    private static func annotatedFrame(videoURL: URL, time: Double, p1: CGPoint, p2: CGPoint) async -> UIImage? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let cmTime = CMTime(seconds: max(0, time), preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) else { return nil }

        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))
            let line = context.cgContext
            line.setStrokeColor(UIColor.systemRed.cgColor)
            line.setLineWidth(max(2, size.width / 250))
            line.move(to: p1)
            line.addLine(to: p2)
            line.strokePath()
        }
    }
}

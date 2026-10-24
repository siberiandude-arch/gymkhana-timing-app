import AVFoundation
import CoreImage
import UIKit

/// Нарезает видео заезда (старт→финиш, с небольшим запасом по краям) и
/// дорисовывает на каждом кадре линию створа и бегущий таймер — чтобы по
/// готовому ролику можно было проверить, как сработал алгоритм, без
/// открытия приложения (можно переслать клип другому райдеру того же
/// упражнения для сверки).
enum VideoExporter {
    enum ExportError: Error {
        case noFinish
        case noVideoTrack
        case emptyRange
        case sessionCreationFailed
        case cancelled
        case failed(String)
    }

    static func exportLap(videoURL: URL, lap: LapAttempt, p1: CGPoint, p2: CGPoint,
                           padding: Double = 1.5) async throws -> URL {
        guard let finish = lap.finish else { throw ExportError.noFinish }

        let asset = AVURLAsset(url: videoURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }

        let assetDuration = try await asset.load(.duration).seconds
        let rangeStart = max(0, lap.start - padding)
        let rangeEnd = min(assetDuration, finish + padding)
        guard rangeEnd > rangeStart else { throw ExportError.emptyRange }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let lineWidth = max(2, naturalSize.width / 250)

        let videoComposition = AVMutableVideoComposition(asset: asset) { request in
            let overlay = Self.overlayImage(
                size: request.renderSize,
                time: request.compositionTime.seconds,
                lapStart: lap.start,
                lapFinish: finish,
                p1: p1,
                p2: p2,
                lineWidth: lineWidth
            )
            request.finish(with: overlay.composited(over: request.sourceImage), context: nil)
        }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.sessionCreationFailed
        }
        exportSession.videoComposition = videoComposition
        exportSession.outputFileType = .mp4
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: rangeStart, preferredTimescale: 600),
            end: CMTime(seconds: rangeEnd, preferredTimescale: 600)
        )

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lap-\(lap.index)-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: outputURL)
        exportSession.outputURL = outputURL

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exportSession.exportAsynchronously { continuation.resume() }
        }

        switch exportSession.status {
        case .completed:
            return outputURL
        case .cancelled:
            throw ExportError.cancelled
        default:
            throw ExportError.failed(exportSession.error.map { "\($0)" } ?? "неизвестная ошибка экспорта")
        }
    }

    /// Рисуется с явным scale=1 — иначе UIGraphicsImageRenderer по умолчанию
    /// возьмёт scale экрана (2x/3x), и полученная CIImage будет в 2-3 раза
    /// крупнее кадра видео (request.renderSize — это пиксели кадра, не points),
    /// линия и таймер лягут не на то место или не в том масштабе.
    private static func overlayImage(size: CGSize, time: Double, lapStart: Double, lapFinish: Double,
                                      p1: CGPoint, p2: CGPoint, lineWidth: CGFloat) -> CIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let cg = context.cgContext
            cg.setStrokeColor(UIColor.systemRed.cgColor)
            cg.setLineWidth(lineWidth)
            cg.move(to: p1)
            cg.addLine(to: p2)
            cg.strokePath()

            let elapsed = max(0, min(time, lapFinish) - lapStart)
            let text = String(format: "%.2f", elapsed)
            let font = UIFont.monospacedDigitSystemFont(ofSize: size.height / 14, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
                .strokeColor: UIColor.black,
                .strokeWidth: -4
            ]
            let string = NSAttributedString(string: text, attributes: attrs)
            let textSize = string.size()
            string.draw(at: CGPoint(x: size.width - textSize.width - 24, y: 24))
        }
        return CIImage(image: image) ?? CIImage.empty()
    }
}

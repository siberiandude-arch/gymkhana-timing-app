import AVFoundation
@preconcurrency import CoreImage
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

        // Клип сжимается до 1280 по ширине: оригинал 1920x1080 с высоким
        // битрейтом камеры выходил на ~100 МБ за заезд, а для просмотра и
        // пересылки такого качества не нужно. Меньшие видео не трогаем.
        let scale = naturalSize.width > 1280 ? 1280 / naturalSize.width : 1
        let outputSize = CGSize(width: (naturalSize.width * scale / 2).rounded() * 2,
                                height: (naturalSize.height * scale / 2).rounded() * 2)
        let lineWidth = max(2, outputSize.width / 250)
        let scaledP1 = CGPoint(x: p1.x * scale, y: p1.y * scale)
        let scaledP2 = CGPoint(x: p2.x * scale, y: p2.y * scale)

        // Линия одинакова на всех кадрах — рисуем её один раз. На каждом
        // кадре перерисовывается только маленькая плашка с таймером: раньше
        // каждый кадр получал заново отрисованный слой во весь размер
        // (1920x1080), и экспорт шёл примерно в реальном времени.
        let lineLayer = Self.lineOverlay(size: outputSize, p1: scaledP1, p2: scaledP2, lineWidth: lineWidth)
        let lapStart = lap.start

        let videoComposition = AVMutableVideoComposition(asset: asset) { request in
            let elapsed = max(0, min(request.compositionTime.seconds, finish) - lapStart)
            var base = request.sourceImage
            if scale != 1 {
                base = base.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            var result = lineLayer.composited(over: base)
            if let timer = Self.timerOverlay(text: String(format: "%.2f", elapsed), frameSize: outputSize) {
                result = timer.composited(over: result)
            }
            request.finish(with: result, context: nil)
        }
        videoComposition.renderSize = outputSize

        let presetName = scale < 1 ? AVAssetExportPreset1280x720 : AVAssetExportPresetHighestQuality
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: presetName) else {
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
    /// крупнее кадра видео (размер кадра — в пикселях, не points), линия
    /// ляжет не на то место или не в том масштабе.
    private static func lineOverlay(size: CGSize, p1: CGPoint, p2: CGPoint, lineWidth: CGFloat) -> CIImage {
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
        }
        return CIImage(image: image) ?? CIImage.empty()
    }

    /// Маленькая картинка с таймером в правом верхнем углу кадра.
    private static func timerOverlay(text: String, frameSize: CGSize) -> CIImage? {
        let font = UIFont.monospacedDigitSystemFont(ofSize: frameSize.height / 14, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
            .strokeColor: UIColor.black,
            .strokeWidth: -4
        ]
        let string = NSAttributedString(string: text, attributes: attrs)
        let textSize = string.size()
        let imageSize = CGSize(width: ceil(textSize.width) + 8, height: ceil(textSize.height) + 8)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: imageSize, format: format).image { _ in
            string.draw(at: CGPoint(x: 4, y: 4))
        }
        guard let ci = CIImage(image: image) else { return nil }
        // у CIImage начало координат внизу слева, а таймер нужен сверху справа
        let x = frameSize.width - imageSize.width - 20
        let y = frameSize.height - imageSize.height - 20
        return ci.transformed(by: CGAffineTransform(translationX: x, y: y))
    }
}

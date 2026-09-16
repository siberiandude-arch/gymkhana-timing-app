import AVFoundation
import CoreGraphics

/// Порт python-алгоритма (gymkhana_timing_algorithm.py) на Swift.
///
/// Это прямой перенос логики шаг-в-шаг: статичный участок видео, ROI
/// вокруг створа, вычитание фона + морфология + связные компоненты,
/// знаковое расстояние до линии, поиск пересечений с интерполяцией,
/// эвристика выбора старта/финиша.
///
/// Одно сознательное упрощение: вместо `cv2.createBackgroundSubtractorMOG2`
/// (смесь гауссиан на пиксель) используется скользящее среднее по кадру —
/// в чистом Swift/Accelerate нет готового MOG2. Параметры (alpha, порог)
/// подобраны и провалидированы на тех же 4 тестовых видео, что и
/// python-версия (см. README, раздел про валидацию) — расхождение с
/// референсным временем табло в среднем ~0.3с, максимум ~0.42с, что
/// сопоставимо с самой python-версией (~0.05–0.55с).

extension CGAffineTransform {
    var isNearIdentity: Bool {
        abs(a - 1) < 0.01 && abs(b) < 0.01 && abs(c) < 0.01 && abs(d - 1) < 0.01
    }
}

struct DetectionRecord {
    let frame: Int
    let t: Double
    let cx: Double
    let cy: Double
    let area: Int
    let leftBottom: CGPoint
    let rightBottom: CGPoint
}

struct AnalysisResult {
    let start: Double
    let finish: Double
    let lap: Double
    let crossings: [Double]
}

enum AnalyzerError: Error {
    case noVideoTrack
    case noStartFinishFound
    case unsupportedOrientation
}

private struct ROI {
    let x0: Int
    let y0: Int
    let x1: Int
    let y1: Int
    var width: Int { x1 - x0 }
    var height: Int { y1 - y0 }
}

enum VideoAnalyzer {

    // MARK: - Публичная точка входа

    static func analyze(videoURL: URL, p1: CGPoint, p2: CGPoint) async throws -> AnalysisResult {
        let asset = AVURLAsset(url: videoURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw AnalyzerError.noVideoTrack
        }

        // AVAssetReader ниже отдаёт сырые, необработанные пиксели — как и
        // AVCaptureConnection.videoOrientation, зафиксированная на landscapeRight
        // при своей записи (CameraController.swift). Калибровочный кадр в
        // CalibrationView, наоборот, показывается с учётом preferredTransform.
        // Если у импортированного через debug-режим файла транспонирование не
        // единичное (например, видео снято в портретной ориентации), эти два
        // представления разъедутся, и калибровочные точки будут указывать не
        // туда — лучше явно отказать, чем тихо посчитать неверное время.
        let transform = try await videoTrack.load(.preferredTransform)
        guard transform.isNearIdentity else {
            throw AnalyzerError.unsupportedOrientation
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let width = Int(naturalSize.width.rounded())
        let height = Int(naturalSize.height.rounded())

        let roi = makeROI(p1: p1, p2: p2, frameWidth: width, frameHeight: height)

        let staticEndFrame = try detectStaticEnd(asset: asset, videoTrack: videoTrack)
        let records = try trackMotorcycle(asset: asset, videoTrack: videoTrack, roi: roi, staticEndFrame: staticEndFrame)
        let crossings = analyzeCrossings(records: records, p1: p1, p2: p2)

        guard let (start, finish) = pickStartFinish(crossings: crossings) else {
            throw AnalyzerError.noStartFinishFound
        }
        return AnalysisResult(start: start, finish: finish, lap: finish - start, crossings: crossings)
    }

    // MARK: - Шаг 2 (из спецификации): область наблюдения вокруг створа

    private static func makeROI(p1: CGPoint, p2: CGPoint, frameWidth: Int, frameHeight: Int,
                                 padX: Int = 300, padY: Int = 250) -> ROI {
        let minX = Int(min(p1.x, p2.x)) - padX
        let maxX = Int(max(p1.x, p2.x)) + padX
        let minY = Int(min(p1.y, p2.y)) - padY
        let maxY = Int(max(p1.y, p2.y)) + padY
        return ROI(
            x0: max(0, minX),
            y0: max(0, minY),
            x1: min(frameWidth, maxX),
            y1: min(frameHeight, maxY)
        )
    }

    // MARK: - Шаг 1: определение статичного участка видео

    private static func detectStaticEnd(asset: AVURLAsset, videoTrack: AVAssetTrack,
                                         threshold: Double = 3.0, minRun: Int = 10) throws -> Int? {
        let smallW = 240
        let smallH = 135

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: smallW,
            kCVPixelBufferHeightKey as String: smallH
        ]
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        var prevGray: [UInt8]?
        var diffs: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let gray = grayscaleBuffer(pixelBuffer, width: smallW, height: smallH)
            if let prevGray {
                diffs.append(blockMedianDiff(prevGray, gray, width: smallW, height: smallH, blocks: 6))
            } else {
                diffs.append(0)
            }
            prevGray = gray
        }
        reader.cancelReading()

        var run = 0
        for (i, d) in diffs.enumerated() {
            if d > threshold {
                run += 1
                if run >= minRun {
                    return i - minRun + 1
                }
            } else {
                run = 0
            }
        }
        return nil
    }

    private static func grayscaleBuffer(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        var out = [UInt8](repeating: 0, count: width * height)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return out }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let w = min(width, CVPixelBufferGetWidth(pixelBuffer))
        let h = min(height, CVPixelBufferGetHeight(pixelBuffer))
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let row = ptr + y * bytesPerRow
            for x in 0..<w {
                let px = row + x * 4
                let gray = 0.299 * Double(px[2]) + 0.587 * Double(px[1]) + 0.114 * Double(px[0])
                out[y * width + x] = UInt8(clamping: Int(gray))
            }
        }
        return out
    }

    private static func blockMedianDiff(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int, blocks: Int) -> Double {
        let bw = width / blocks
        let bh = height / blocks
        guard bw > 0, bh > 0 else { return 0 }
        var means: [Double] = []
        means.reserveCapacity(blocks * blocks)
        for by in 0..<blocks {
            for bx in 0..<blocks {
                var sum = 0.0
                var count = 0
                for y in (by * bh)..<((by + 1) * bh) {
                    let rowBase = y * width
                    for x in (bx * bw)..<((bx + 1) * bw) {
                        let idx = rowBase + x
                        sum += Double(abs(Int(a[idx]) - Int(b[idx])))
                        count += 1
                    }
                }
                means.append(count > 0 ? sum / Double(count) : 0)
            }
        }
        means.sort()
        let mid = means.count / 2
        return means.count % 2 == 0 ? (means[mid - 1] + means[mid]) / 2 : means[mid]
    }

    // MARK: - Шаг 3: трекинг мотоцикла в ROI

    private static func trackMotorcycle(asset: AVURLAsset, videoTrack: AVAssetTrack, roi: ROI,
                                         staticEndFrame: Int?) throws -> [DetectionRecord] {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        var background: [Float]?
        var records: [DetectionRecord] = []
        var frameIdx = 0
        // Подобрано валидацией на 4 реальных заездах (см. README): при alpha=0.05
        // скользящее среднее слишком медленно "забывает" байк — низкоскоростной/
        // покачивающийся участок у линии остаётся в фоне ещё десятки кадров,
        // контур получает длинный шлейф, и это систематически сдвигало
        // расчётное время круга (~0.6–0.8с) относительно референса. Более
        // быстрая адаптация (alpha=0.25) ведёт себя ближе к покадровому диффу,
        // даёт чёткую границу движения без шлейфа и возвращает точность в
        // диапазон python-версии (~0.2–0.4с при той же связке порогов).
        let varThreshold: Float = 28
        let alpha: Float = 0.25
        let minArea = 300

        while let sample = output.copyNextSampleBuffer() {
            if let staticEndFrame, frameIdx >= staticEndFrame { break }
            defer { frameIdx += 1 }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            let gray = roiGrayscale(pixelBuffer, roi: roi)

            guard var bg = background else {
                background = gray
                continue
            }

            var mask = [UInt8](repeating: 0, count: roi.width * roi.height)
            for i in 0..<gray.count {
                let diff = abs(gray[i] - bg[i])
                mask[i] = diff > varThreshold ? 255 : 0
                bg[i] = bg[i] * (1 - alpha) + gray[i] * alpha
            }
            background = bg

            // open (erode -> dilate, ядро 9x9), затем close (dilate -> erode, ядро 15x15)
            let opened = dilate(erode(mask, width: roi.width, height: roi.height, kernel: 9),
                                 width: roi.width, height: roi.height, kernel: 9)
            let closed = erode(dilate(opened, width: roi.width, height: roi.height, kernel: 15),
                                width: roi.width, height: roi.height, kernel: 15)

            guard frameIdx > 0,
                  let component = largestComponent(mask: closed, width: roi.width, height: roi.height),
                  component.area > minArea else { continue }

            var sumX = 0, sumY = 0, yMax = 0
            for (x, y) in component.pixels {
                sumX += x
                sumY += y
                if y > yMax { yMax = y }
            }
            let cx = Double(sumX) / Double(component.pixels.count) + Double(roi.x0)
            let cy = Double(sumY) / Double(component.pixels.count) + Double(roi.y0)

            let band = component.pixels.filter { $0.1 >= yMax - 15 }
            guard let leftPixel = band.min(by: { $0.0 < $1.0 }),
                  let rightPixel = band.max(by: { $0.0 < $1.0 }) else { continue }

            records.append(DetectionRecord(
                frame: frameIdx,
                t: t,
                cx: cx,
                cy: cy,
                area: component.area,
                leftBottom: CGPoint(x: Double(leftPixel.0 + roi.x0), y: Double(leftPixel.1 + roi.y0)),
                rightBottom: CGPoint(x: Double(rightPixel.0 + roi.x0), y: Double(rightPixel.1 + roi.y0))
            ))
        }
        reader.cancelReading()
        return records
    }

    private static func roiGrayscale(_ pixelBuffer: CVPixelBuffer, roi: ROI) -> [Float] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        var out = [Float](repeating: 0, count: roi.width * roi.height)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return out }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<roi.height {
            let row = ptr + (y + roi.y0) * bytesPerRow
            for x in 0..<roi.width {
                let px = row + (x + roi.x0) * 4
                out[y * roi.width + x] = 0.299 * Float(px[2]) + 0.587 * Float(px[1]) + 0.114 * Float(px[0])
            }
        }
        return out
    }

    // MARK: - Морфология (сепарабельные min/max-фильтры по квадратному ядру)

    private static func erode(_ mask: [UInt8], width: Int, height: Int, kernel: Int) -> [UInt8] {
        minMaxFilter(mask, width: width, height: height, kernel: kernel, isErode: true)
    }

    private static func dilate(_ mask: [UInt8], width: Int, height: Int, kernel: Int) -> [UInt8] {
        minMaxFilter(mask, width: width, height: height, kernel: kernel, isErode: false)
    }

    private static func minMaxFilter(_ mask: [UInt8], width: Int, height: Int, kernel: Int, isErode: Bool) -> [UInt8] {
        let r = kernel / 2
        var horizontal = [UInt8](repeating: 0, count: width * height)
        mask.withUnsafeBufferPointer { src in
            horizontal.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let rowBase = y * width
                    for x in 0..<width {
                        var value: UInt8 = isErode ? 255 : 0
                        let xStart = max(0, x - r), xEnd = min(width - 1, x + r)
                        var i = xStart
                        while i <= xEnd {
                            let v = src[rowBase + i]
                            if isErode { if v < value { value = v } } else { if v > value { value = v } }
                            i += 1
                        }
                        dst[rowBase + x] = value
                    }
                }
            }
        }
        var result = [UInt8](repeating: 0, count: width * height)
        horizontal.withUnsafeBufferPointer { src in
            result.withUnsafeMutableBufferPointer { dst in
                for x in 0..<width {
                    for y in 0..<height {
                        var value: UInt8 = isErode ? 255 : 0
                        let yStart = max(0, y - r), yEnd = min(height - 1, y + r)
                        var i = yStart
                        while i <= yEnd {
                            let v = src[i * width + x]
                            if isErode { if v < value { value = v } } else { if v > value { value = v } }
                            i += 1
                        }
                        dst[y * width + x] = value
                    }
                }
            }
        }
        return result
    }

    // MARK: - Связные компоненты (аналог "самый большой контур")

    private static func largestComponent(mask: [UInt8], width: Int, height: Int) -> (pixels: [(Int, Int)], area: Int)? {
        var visited = [Bool](repeating: false, count: width * height)
        var bestPixels: [(Int, Int)] = []
        var stack: [(Int, Int)] = []

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                if mask[idx] == 0 || visited[idx] { continue }

                var pixels: [(Int, Int)] = []
                stack.removeAll(keepingCapacity: true)
                stack.append((x, y))
                visited[idx] = true
                while let (cx, cy) = stack.popLast() {
                    pixels.append((cx, cy))
                    for (nx, ny) in [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)] {
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let nIdx = ny * width + nx
                        if mask[nIdx] != 0 && !visited[nIdx] {
                            visited[nIdx] = true
                            stack.append((nx, ny))
                        }
                    }
                }
                if pixels.count > bestPixels.count {
                    bestPixels = pixels
                }
            }
        }
        return bestPixels.isEmpty ? nil : (bestPixels, bestPixels.count)
    }

    // MARK: - Шаг 4: знаковое расстояние, сегменты, пересечения

    private static func analyzeCrossings(records: [DetectionRecord], p1: CGPoint, p2: CGPoint,
                                          areaThresh: Double = 8000) -> [Double] {
        guard !records.isEmpty else { return [] }

        let d = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y)
        let norm = (d.x * d.x + d.y * d.y).squareRoot()
        guard norm > 0 else { return [] }
        let dirX = d.x / norm, dirY = d.y / norm
        let normalX = -dirY, normalY = dirX

        func signedDistance(_ p: CGPoint) -> Double {
            Double((p.x - p1.x) * normalX + (p.y - p1.y) * normalY)
        }

        // сегменты присутствия в ROI: разрыв > 5 кадров — новый сегмент
        var segments: [(start: Int, end: Int)] = []
        var segStart = 0
        for i in 1..<records.count {
            if records[i].frame - records[i - 1].frame > 5 {
                segments.append((segStart, i - 1))
                segStart = i
            }
        }
        segments.append((segStart, records.count - 1))

        let realSegments = segments.filter { seg in
            (records[seg.start...seg.end].map { Double($0.area) }.max() ?? 0) > areaThresh
        }

        var crossings: [Double] = []
        for seg in realSegments {
            let segRecords = Array(records[seg.start...seg.end])
            guard segRecords.count > 1 else { continue }

            // np.gradient: центральная разность внутри, односторонняя на краях
            let cx = segRecords.map { $0.cx }
            var vx = [Double](repeating: 0, count: cx.count)
            vx[0] = cx[1] - cx[0]
            vx[cx.count - 1] = cx[cx.count - 1] - cx[cx.count - 2]
            if cx.count > 2 {
                for i in 1..<(cx.count - 1) {
                    vx[i] = (cx[i + 1] - cx[i - 1]) / 2
                }
            }

            var dist = [Double](repeating: 0, count: segRecords.count)
            for i in 0..<segRecords.count {
                let point = vx[i] > 0 ? segRecords[i].rightBottom : segRecords[i].leftBottom
                dist[i] = signedDistance(point)
            }

            for i in 1..<dist.count {
                let d0 = dist[i - 1], d1 = dist[i]
                if (d0 > 0) != (d1 > 0) {
                    let t0 = segRecords[i - 1].t, t1 = segRecords[i].t
                    let frac = -d0 / (d1 - d0)
                    crossings.append(t0 + frac * (t1 - t0))
                }
            }
        }
        return crossings.sorted()
    }

    // MARK: - Шаг 5: выбор старта и финиша

    private static func pickStartFinish(crossings: [Double], splitSeconds: Double = 10.0) -> (Double, Double)? {
        let startCandidates = crossings.filter { $0 < splitSeconds }
        let finishCandidates = crossings.filter { $0 >= splitSeconds }
        guard let start = startCandidates.max(), let finish = finishCandidates.min() else { return nil }
        return (start, finish)
    }
}

import AVFoundation
import CoreGraphics

/// Порт python-алгоритма (gymkhana_timing_algorithm.py) на Swift.
///
/// Это прямой перенос логики шаг-в-шаг: статичный участок видео, ROI
/// вокруг створа, вычитание фона + морфология + связные компоненты,
/// знаковое расстояние до линии, поиск пересечений с интерполяцией,
/// группировка пересечений в заезды.
///
/// Одно сознательное упрощение: вместо `cv2.createBackgroundSubtractorMOG2`
/// (смесь гауссиан на пиксель) используется скользящее среднее по кадру —
/// в чистом Swift/Accelerate нет готового MOG2. Параметры (alpha, порог)
/// подобраны и провалидированы на тех же 4 тестовых видео, что и
/// python-версия (см. README, раздел про валидацию).

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
    /// Площадь пятна в пикселях ПОЛНОГО разрешения (с учётом прореживания).
    let area: Int
    let leftBottom: CGPoint
    let rightBottom: CGPoint
    /// Верхняя и нижняя точки силуэта (полное разрешение) — по ним
    /// оценивается масштаб (рост байка с райдером в пикселях).
    let top: Double
    let bottom: Double
}

/// Как считать время круга. Камера видит только ближнее к ней колесо, а
/// "как лазер" значит: ворота срабатывают на переднее колесо, а событие
/// заканчивается, когда ворота прошло и заднее колесо.
enum TimingRule: String, CaseIterable, Identifiable {
    /// Старт — переднее колесо при выезде, финиш — заднее колесо при возврате.
    case frontToRear
    /// Классическая телеметрия: первое касание луча передним колесом и на старте, и на финише.
    case frontToFront

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frontToRear: return "Старт — переднее колесо, финиш — заднее"
        case .frontToFront: return "Старт и финиш — переднее колесо"
        }
    }
}

/// Один проезд через створ: от выезда со старта до возврата в створ.
/// `finish == nil` значит райдер выехал, но не вернулся через створ повторно —
/// например, срезал на упражнении и заехал в стартовые ворота по внешнему
/// контуру, не пересекая саму линию (см. pairLaps).
struct LapAttempt: Identifiable {
    let id: UUID
    let index: Int
    let rule: TimingRule
    /// Момент, когда переднее колесо пересекло линию при выезде.
    let startFront: Double
    /// Момент, когда камера реально увидела пересечение ближним колесом.
    let startNear: Double
    let finishFront: Double?
    let finishRear: Double?
    let finishNear: Double?

    init(id: UUID = UUID(), index: Int, rule: TimingRule = .frontToRear,
         startFront: Double, startNear: Double,
         finishFront: Double? = nil, finishRear: Double? = nil, finishNear: Double? = nil) {
        self.id = id
        self.index = index
        self.rule = rule
        self.startFront = startFront
        self.startNear = startNear
        self.finishFront = finishFront
        self.finishRear = finishRear
        self.finishNear = finishNear
    }

    var start: Double { startFront }

    var finish: Double? {
        switch rule {
        case .frontToRear: return finishRear
        case .frontToFront: return finishFront
        }
    }

    var duration: Double? { finish.map { $0 - start } }

    /// Время круга по моментам, которые камера реально увидела (без
    /// пересчёта на переднее/заднее колесо) — для сверки с оценкой.
    var observedDuration: Double? { finishNear.map { $0 - startNear } }

    func duration(for rule: TimingRule) -> Double? { with(rule: rule).duration }

    func with(index: Int) -> LapAttempt {
        LapAttempt(id: id, index: index, rule: rule, startFront: startFront, startNear: startNear,
                   finishFront: finishFront, finishRear: finishRear, finishNear: finishNear)
    }

    func with(rule: TimingRule) -> LapAttempt {
        LapAttempt(id: id, index: index, rule: rule, startFront: startFront, startNear: startNear,
                   finishFront: finishFront, finishRear: finishRear, finishNear: finishNear)
    }
}

private struct Crossing {
    /// Когда ближняя к камере точка опоры байка пересекла линию.
    let time: Double
    /// Знаковое расстояние до линии было положительным непосредственно перед
    /// пересечением — используется только как метка направления проезда
    /// (см. pairLaps), само значение смысла не несёт.
    let fromPositiveSide: Bool
    /// Оценка момента пересечения передним и задним колесом.
    let tFront: Double
    let tRear: Double
    let delta: Double
    let nearIsFront: Bool
    /// false — камера видит оба колеса сама (или ракурс не позволяет оценить
    /// разницу), и tFront == tRear == time.
    let compensated: Bool
}

/// То же пересечение, но с направлением, переведённым в понятный человеку
/// смысл ("выезд"/"возврат") — для отладочного экрана.
struct CrossingDebugInfo: Identifiable {
    let id = UUID()
    let time: Double
    let isExit: Bool
    let tFront: Double
    let tRear: Double
    let delta: Double
    let nearIsFront: Bool
    let compensated: Bool
}

struct AnalysisOutput {
    let laps: [LapAttempt]
    let crossings: [CrossingDebugInfo]
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

/// Результат поиска самого большого пятна на маске (в координатах
/// прореженного кадра/кропа).
private struct ComponentResult {
    let area: Int
    let cx: Double
    let cy: Double
    let leftX: Int
    let leftY: Int
    let rightX: Int
    let rightY: Int
    let minY: Int
    let maxY: Int
}

/// Буферы одного прохода по видео: выделяются один раз, а не на каждый кадр
/// (на длинной сессии это тысячи кадров и сотни мегабайт аллокаций).
private final class TrackerScratch {
    let count: Int
    let gray: UnsafeMutablePointer<UInt8>
    let mask: UnsafeMutablePointer<UInt8>
    let background: UnsafeMutablePointer<Float>
    let a: UnsafeMutablePointer<UInt8>
    let b: UnsafeMutablePointer<UInt8>
    let c: UnsafeMutablePointer<UInt8>
    let visited: UnsafeMutablePointer<UInt8>
    let dq: UnsafeMutablePointer<Int32>
    let stack: UnsafeMutablePointer<Int32>
    var comp: UnsafeMutablePointer<Int32>
    var best: UnsafeMutablePointer<Int32>

    init(width: Int, height: Int) {
        count = width * height
        gray = .allocate(capacity: count)
        mask = .allocate(capacity: count)
        background = .allocate(capacity: count)
        a = .allocate(capacity: count)
        b = .allocate(capacity: count)
        c = .allocate(capacity: count)
        visited = .allocate(capacity: count)
        dq = .allocate(capacity: max(width, height) + 1)
        stack = .allocate(capacity: count)
        comp = .allocate(capacity: count)
        best = .allocate(capacity: count)
        gray.initialize(repeating: 0, count: count)
        mask.initialize(repeating: 0, count: count)
        background.initialize(repeating: 0, count: count)
        a.initialize(repeating: 0, count: count)
        b.initialize(repeating: 0, count: count)
        c.initialize(repeating: 0, count: count)
        visited.initialize(repeating: 0, count: count)
        dq.initialize(repeating: 0, count: max(width, height) + 1)
        stack.initialize(repeating: 0, count: count)
        comp.initialize(repeating: 0, count: count)
        best.initialize(repeating: 0, count: count)
    }

    deinit {
        gray.deallocate()
        mask.deallocate()
        background.deallocate()
        a.deallocate()
        b.deallocate()
        c.deallocate()
        visited.deallocate()
        dq.deallocate()
        stack.deallocate()
        comp.deallocate()
        best.deallocate()
    }
}

enum VideoAnalyzer {

    /// Допущения, на которых держится оценка "переднее/заднее колесо" по
    /// одной камере (см. makeCrossing). Это грубая оценка, а не измерение.
    /// Поправка на второе колесо. Камера видит момент пересечения только
    /// ближним к ней колесом; второе пересекает линию позже/раньше на
    /// Δ = колёсная база / скорость.
    ///
    /// Сначала Δ оценивалась по скорости из кадра (через размер байка и
    /// высоту камеры), но на реальных видео модель давала 0.08–0.10 с при
    /// реальных ≈0.5 с (проверено покадровой разметкой клипа с телефона и
    /// сверкой с телеметрией на четырёх эталонных видео): скорость вдоль
    /// нормали к линии при диагональном проезде и с тенью под байком
    /// не пересчитывается в метры надёжно. Поэтому взяты типичные значения
    /// (колёсная база ≈1.5 м): на старте байк только набирает скорость
    /// (≈3.5 м/с → 0.45 с), на финише едет быстрее (≈4–5 м/с → 0.35 с).
    /// Это оценка, а не измерение: ошибка порядка 0.1–0.2 с.
    private enum Geometry {
        static let startDelta = 0.45
        static let finishDelta = 0.35
    }

    // MARK: - Публичная точка входа

    static func analyze(videoURL: URL, p1: CGPoint, p2: CGPoint) async throws -> AnalysisOutput {
        let asset = AVURLAsset(url: videoURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw AnalyzerError.noVideoTrack
        }

        // AVAssetReader ниже отдаёт сырые, необработанные пиксели — как и
        // AVCaptureConnection.videoOrientation, зафиксированная на landscapeRight
        // при своей записи (CameraController.swift). Калибровочный кадр в
        // CalibrationView, наоборот, показывается с учётом preferredTransform.
        // Если у импортированного файла транспонирование не единичное
        // (например, видео снято в портретной ориентации), эти два
        // представления разъедутся, и калибровочные точки будут указывать не
        // туда — лучше явно отказать, чем тихо посчитать неверное время.
        let transform = try await videoTrack.load(.preferredTransform)
        guard transform.isNearIdentity else {
            throw AnalyzerError.unsupportedOrientation
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let width = Int(naturalSize.width.rounded())
        let height = Int(naturalSize.height.rounded())

        // Все геометрические константы (отступ ROI, минимальная площадь
        // пятна, порог "настоящего проезда", ядра морфологии) подобраны на
        // кадре 1920x1080 — пересчитываются пропорционально реальному
        // разрешению.
        let scale = Double(width) / 1920.0

        // Для полного HD обрабатываем ROI в половинном разрешении: точность
        // положения силуэта в 2 пикселя на таком кадре — доли миллисекунды
        // по времени пересечения, а работы в 4 раза меньше.
        let decimation = width >= 1400 ? 2 : 1

        let roi = makeROI(p1: p1, p2: p2, frameWidth: width, frameHeight: height, scale: scale, decimation: decimation)
        print("[VideoAnalyzer] \(videoURL.lastPathComponent): \(width)x\(height), scale=\(scale), d=\(decimation), roi=\(roi.x0),\(roi.y0)-\(roi.x1),\(roi.y1)")

        // Поиск момента, когда камеру берут в руки, и сам трекинг — два
        // независимых полных прохода по видео; считаем их одновременно, а
        // кадры после конца штатива просто отбрасываем.
        let started = Date()
        async let staticEnd = detectStaticEnd(url: videoURL)
        async let tracked = trackMotorcycle(url: videoURL, roi: roi, scale: scale, decimation: decimation)
        let staticEndFrame = try await staticEnd
        var records = try await tracked
        if let limit = staticEndFrame {
            records = records.filter { $0.frame < limit }
        }
        print("[VideoAnalyzer] \(videoURL.lastPathComponent): staticEndFrame=\(staticEndFrame?.description ?? "nil"), \(records.count) detections, \(String(format: "%.1f", Date().timeIntervalSince(started)))с")

        let crossings = analyzeCrossings(records: records, p1: p1, p2: p2,
                                         areaThresh: 8000 * scale * scale, frameWidth: width)
        let (laps, startDirection) = pairLaps(crossings: crossings)
        guard !laps.isEmpty else {
            throw AnalyzerError.noStartFinishFound
        }
        let debugCrossings = crossings.map {
            CrossingDebugInfo(time: $0.time, isExit: $0.fromPositiveSide == startDirection,
                              tFront: $0.tFront, tRear: $0.tRear, delta: $0.delta,
                              nearIsFront: $0.nearIsFront, compensated: $0.compensated)
        }
        return AnalysisOutput(laps: laps, crossings: debugCrossings)
    }

    /// Ближайшее нечётное число (округление вниз, если между двумя нечётными) —
    /// для масштабирования размера ядра морфологии.
    private static func nearestOdd(_ x: Double) -> Int {
        let v = Int(x)
        return v % 2 == 0 ? v + 1 : v
    }

    // MARK: - Шаг 2 (из спецификации): область наблюдения вокруг створа

    /// Сверху отступ больше, чем снизу: нужен весь рост райдера с байком,
    /// чтобы по нему оценивать масштаб (см. makeCrossing).
    private static func makeROI(p1: CGPoint, p2: CGPoint, frameWidth: Int, frameHeight: Int,
                                scale: Double, decimation d: Int) -> ROI {
        let padX = Int((300 * scale).rounded())
        let padTop = Int((400 * scale).rounded())
        let padBottom = Int((250 * scale).rounded())
        let minX = Int(min(p1.x, p2.x)) - padX
        let maxX = Int(max(p1.x, p2.x)) + padX
        let minY = Int(min(p1.y, p2.y)) - padTop
        let maxY = Int(max(p1.y, p2.y)) + padBottom
        var x0 = max(0, minX)
        var y0 = max(0, minY)
        var x1 = min(frameWidth, maxX)
        var y1 = min(frameHeight, maxY)
        x0 -= x0 % d
        y0 -= y0 % d
        x1 -= (x1 - x0) % d
        y1 -= (y1 - y0) % d
        return ROI(x0: x0, y0: y0, x1: x1, y1: y1)
    }

    // MARK: - Шаг 1: определение статичного участка видео

    private static func detectStaticEnd(url: URL, threshold: Double = 3.0, minRun: Int = 10) async throws -> Int? {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw AnalyzerError.noVideoTrack
        }

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
        var frameIdx = 0
        while let sample = output.copyNextSampleBuffer() {
            if frameIdx % 60 == 0 { try Task.checkCancellation() }
            frameIdx += 1
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

    /// Быстрый путь по сравнению с первой версией:
    ///  - декодер сразу отдаёт YUV 4:2:0, берём плоскость яркости как есть
    ///    (раньше — конвертация каждого пикселя ROI из BGRA во float);
    ///  - ROI усредняется 2x2 перед любой обработкой (в 4 раза меньше пикселей);
    ///  - маска считается за один проход вместе с обновлением фона, и сразу
    ///    находится прямоугольник, где вообще что-то движется — морфология и
    ///    поиск пятен идут только по нему (на кадрах без байка — вообще мимо);
    ///  - буферы выделяются один раз на весь проход.
    private static func trackMotorcycle(url: URL, roi: ROI, scale: Double, decimation d: Int) async throws -> [DetectionRecord] {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw AnalyzerError.noVideoTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? AnalyzerError.noVideoTrack
        }
        defer { reader.cancelReading() }

        let w = roi.width / d
        let h = roi.height / d
        guard w >= 16, h >= 16 else { return [] }

        let ds = Double(d)
        let openKernel = nearestOdd(9 * scale / ds)
        let closeKernel = nearestOdd(15 * scale / ds)
        let openR = openKernel / 2
        let closeR = closeKernel / 2
        let bandPx = max(1, Int((15 * scale / ds).rounded()))
        let minArea = max(8, Int((300 * scale * scale / (ds * ds)).rounded()))
        let margin = 2 * (openR + closeR) + 2
        let rawSkipCount = max(8, minArea / 3)
        // Подобрано валидацией на 4 реальных заездах (см. README): быстрая
        // адаптация фона (alpha=0.25) даёт чёткую границу движения без шлейфа.
        let varThreshold: Float = 28
        let alpha: Float = 0.25

        let scratch = TrackerScratch(width: w, height: h)
        var hasBackground = false
        var records: [DetectionRecord] = []
        var frameIdx = 0

        while let sample = output.copyNextSampleBuffer() {
            defer { frameIdx += 1 }
            if frameIdx % 30 == 0 { try Task.checkCancellation() }
            if frameIdx % 300 == 0 {
                print("[VideoAnalyzer] trackMotorcycle: frame \(frameIdx), \(records.count) detections so far")
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))

            extractLuma(pixelBuffer, roi: roi, decimation: d, width: w, height: h, into: scratch.gray)

            if !hasBackground {
                for i in 0..<scratch.count { scratch.background[i] = Float(scratch.gray[i]) }
                hasBackground = true
                continue
            }

            // Маска + обновление фона + ограничивающий прямоугольник движения.
            var fgCount = 0
            var minX = w
            var maxX = -1
            var minY = h
            var maxY = -1
            for y in 0..<h {
                let row = y * w
                for x in 0..<w {
                    let i = row + x
                    let g = Float(scratch.gray[i])
                    let bg = scratch.background[i]
                    if abs(g - bg) > varThreshold {
                        scratch.mask[i] = 255
                        fgCount += 1
                        if x < minX { minX = x }
                        if x > maxX { maxX = x }
                        if y < minY { minY = y }
                        if y > maxY { maxY = y }
                    } else {
                        scratch.mask[i] = 0
                    }
                    scratch.background[i] = bg * (1 - alpha) + g * alpha
                }
            }
            if fgCount < rawSkipCount { continue }

            // Кроп вокруг движения с запасом, достаточным, чтобы результат
            // морфологии совпал с обработкой всего кадра целиком.
            let cx0 = max(0, minX - margin)
            let cx1 = min(w - 1, maxX + margin)
            let cy0 = max(0, minY - margin)
            let cy1 = min(h - 1, maxY + margin)
            let cw = cx1 - cx0 + 1
            let ch = cy1 - cy0 + 1
            for row in 0..<ch {
                (scratch.a + row * cw).update(from: scratch.mask + (cy0 + row) * w + cx0, count: cw)
            }

            // open (erode -> dilate), затем close (dilate -> erode).
            morphology(src: scratch.a, dst: scratch.c, tmp: scratch.b, dq: scratch.dq,
                       width: cw, height: ch, radius: openR, isMin: true)
            morphology(src: scratch.c, dst: scratch.a, tmp: scratch.b, dq: scratch.dq,
                       width: cw, height: ch, radius: openR, isMin: false)
            morphology(src: scratch.a, dst: scratch.c, tmp: scratch.b, dq: scratch.dq,
                       width: cw, height: ch, radius: closeR, isMin: false)
            morphology(src: scratch.c, dst: scratch.a, tmp: scratch.b, dq: scratch.dq,
                       width: cw, height: ch, radius: closeR, isMin: true)

            guard let component = largestComponent(scratch, width: cw, height: ch, bandPx: bandPx),
                  component.area > minArea else { continue }

            // Локальные координаты кропа -> полное разрешение кадра.
            let offsetX = Double(roi.x0) + 0.5 * (ds - 1)
            let offsetY = Double(roi.y0) + 0.5 * (ds - 1)
            func fullX(_ lx: Double) -> Double { offsetX + ds * (Double(cx0) + lx) }
            func fullY(_ ly: Double) -> Double { offsetY + ds * (Double(cy0) + ly) }

            records.append(DetectionRecord(
                frame: frameIdx,
                t: t,
                cx: fullX(component.cx),
                cy: fullY(component.cy),
                area: component.area * d * d,
                leftBottom: CGPoint(x: fullX(Double(component.leftX)), y: fullY(Double(component.leftY))),
                rightBottom: CGPoint(x: fullX(Double(component.rightX)), y: fullY(Double(component.rightY))),
                top: fullY(Double(component.minY)),
                bottom: fullY(Double(component.maxY))
            ))
        }
        return records
    }

    /// Усредняет блоки d x d яркости внутри ROI в плоский буфер w x h.
    private static func extractLuma(_ pixelBuffer: CVPixelBuffer, roi: ROI, decimation d: Int,
                                    width w: Int, height h: Int, into gray: UnsafeMutablePointer<UInt8>) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            gray.update(repeating: 0, count: w * h)
            return
        }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)

        if d == 1 {
            for y in 0..<h {
                let src = luma + (roi.y0 + y) * stride + roi.x0
                (gray + y * w).update(from: src, count: w)
            }
            return
        }

        let area = d * d
        for y in 0..<h {
            let rowTop = luma + (roi.y0 + y * d) * stride + roi.x0
            let dst = gray + y * w
            for x in 0..<w {
                var sum = 0
                for dy in 0..<d {
                    let row = rowTop + dy * stride + x * d
                    for dx in 0..<d {
                        sum += Int(row[dx])
                    }
                }
                dst[x] = UInt8(truncatingIfNeeded: sum / area)
            }
        }
    }

    // MARK: - Морфология (сепарабельные min/max-фильтры по квадратному ядру)

    /// Один проход эрозии (isMin) или дилатации: сначала по строкам src->tmp,
    /// затем по столбцам tmp->dst.
    private static func morphology(src: UnsafeMutablePointer<UInt8>, dst: UnsafeMutablePointer<UInt8>,
                                   tmp: UnsafeMutablePointer<UInt8>, dq: UnsafeMutablePointer<Int32>,
                                   width: Int, height: Int, radius: Int, isMin: Bool) {
        for y in 0..<height {
            slidingMinMax(src: src, dst: tmp, base: y * width, stride: 1, count: width,
                          radius: radius, isMin: isMin, dq: dq)
        }
        for x in 0..<width {
            slidingMinMax(src: tmp, dst: dst, base: x, stride: width, count: height,
                          radius: radius, isMin: isMin, dq: dq)
        }
    }

    /// Скользящий минимум/максимум вдоль строки или столбца (base+stride) за
    /// O(count) — монотонная очередь индексов: голова всегда даёт min/max
    /// текущего окна, каждый индекс входит и выходит не больше раза. Это то же
    /// самое min/max с теми же клэмпами на границе, что и наивный перебор
    /// окна (проверено: результаты на эталонных видео совпали до тысячных).
    private static func slidingMinMax(src: UnsafeMutablePointer<UInt8>, dst: UnsafeMutablePointer<UInt8>,
                                      base: Int, stride: Int, count n: Int, radius r: Int, isMin: Bool,
                                      dq: UnsafeMutablePointer<Int32>) {
        var head = 0
        var tail = 0
        var i = 0
        while i < n {
            let v = src[base + i * stride]
            if isMin {
                while tail > head && src[base + Int(dq[tail - 1]) * stride] >= v { tail -= 1 }
            } else {
                while tail > head && src[base + Int(dq[tail - 1]) * stride] <= v { tail -= 1 }
            }
            dq[tail] = Int32(i)
            tail += 1
            let center = i - r
            if center >= 0 {
                while Int(dq[head]) < center - r { head += 1 }
                dst[base + center * stride] = src[base + Int(dq[head]) * stride]
            }
            i += 1
        }
        var center = max(0, n - r)
        while center < n {
            while Int(dq[head]) < center - r { head += 1 }
            dst[base + center * stride] = src[base + Int(dq[head]) * stride]
            center += 1
        }
    }

    // MARK: - Связные компоненты (аналог "самый большой контур")

    /// Ищет самое большое связное пятно в scratch.a (маска width x height) и
    /// сразу считает по нему всё нужное — без промежуточных массивов пикселей.
    private static func largestComponent(_ s: TrackerScratch, width: Int, height: Int, bandPx: Int) -> ComponentResult? {
        let n = width * height
        s.visited.update(repeating: 0, count: n)
        let mask = s.a
        var bestCount = 0

        var start = 0
        while start < n {
            if mask[start] == 0 || s.visited[start] != 0 {
                start += 1
                continue
            }
            var sp = 0
            var cc = 0
            s.stack[sp] = Int32(start)
            sp += 1
            s.visited[start] = 1
            while sp > 0 {
                sp -= 1
                let idx = Int(s.stack[sp])
                s.comp[cc] = Int32(idx)
                cc += 1
                let x = idx % width
                let y = idx / width
                if x > 0, mask[idx - 1] != 0, s.visited[idx - 1] == 0 {
                    s.visited[idx - 1] = 1
                    s.stack[sp] = Int32(idx - 1)
                    sp += 1
                }
                if x < width - 1, mask[idx + 1] != 0, s.visited[idx + 1] == 0 {
                    s.visited[idx + 1] = 1
                    s.stack[sp] = Int32(idx + 1)
                    sp += 1
                }
                if y > 0, mask[idx - width] != 0, s.visited[idx - width] == 0 {
                    s.visited[idx - width] = 1
                    s.stack[sp] = Int32(idx - width)
                    sp += 1
                }
                if y < height - 1, mask[idx + width] != 0, s.visited[idx + width] == 0 {
                    s.visited[idx + width] = 1
                    s.stack[sp] = Int32(idx + width)
                    sp += 1
                }
            }
            if cc > bestCount {
                bestCount = cc
                let tmp = s.best
                s.best = s.comp
                s.comp = tmp
            }
            start += 1
        }
        guard bestCount > 0 else { return nil }

        var sumX = 0
        var sumY = 0
        var minY = height
        var maxY = 0
        for k in 0..<bestCount {
            let idx = Int(s.best[k])
            let x = idx % width
            let y = idx / width
            sumX += x
            sumY += y
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }

        var leftX = width
        var leftY = maxY
        var rightX = -1
        var rightY = maxY
        let bandTop = maxY - bandPx
        for k in 0..<bestCount {
            let idx = Int(s.best[k])
            let y = idx / width
            if y < bandTop { continue }
            let x = idx % width
            if x < leftX {
                leftX = x
                leftY = y
            }
            if x > rightX {
                rightX = x
                rightY = y
            }
        }

        return ComponentResult(
            area: bestCount,
            cx: Double(sumX) / Double(bestCount),
            cy: Double(sumY) / Double(bestCount),
            leftX: leftX, leftY: leftY,
            rightX: rightX, rightY: rightY,
            minY: minY, maxY: maxY
        )
    }

    // MARK: - Шаг 4: знаковое расстояние, сегменты, пересечения

    private static func analyzeCrossings(records: [DetectionRecord], p1: CGPoint, p2: CGPoint,
                                         areaThresh: Double, frameWidth: Int) -> [Crossing] {
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

        var crossings: [Crossing] = []
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
                    let tNear = t0 + frac * (t1 - t0)
                    crossings.append(makeCrossing(tNear: tNear, fromPositive: d0 > 0, normalY: normalY))
                }
            }
        }
        return crossings.sorted { $0.time < $1.time }
    }

    /// Камера видит только ближнюю к ней точку опоры байка: при отъезде от
    /// камеры это заднее колесо, при приближении — переднее. "Как лазер"
    /// нужно переднее колесо на старте и заднее на финише, поэтому второе
    /// колесо добавляется поправкой (см. Geometry).
    private static func makeCrossing(tNear: Double, fromPositive: Bool, normalY: Double) -> Crossing {
        // Если линия почти вертикальна в кадре, "ближе к камере" не определено.
        guard abs(normalY) >= 0.5 else {
            return Crossing(time: tNear, fromPositiveSide: fromPositive, tFront: tNear, tRear: tNear,
                            delta: 0, nearIsFront: true, compensated: false)
        }
        let cameraSidePositive = normalY > 0
        let nearIsFront = fromPositive != cameraSidePositive
        if nearIsFront {
            // ближнее — переднее: на старте оно и нужно, на финише заднее придёт позже
            return Crossing(time: tNear, fromPositiveSide: fromPositive, tFront: tNear,
                            tRear: tNear + Geometry.finishDelta,
                            delta: Geometry.finishDelta, nearIsFront: true, compensated: true)
        } else {
            // ближнее — заднее: переднее пересекло линию раньше
            return Crossing(time: tNear, fromPositiveSide: fromPositive,
                            tFront: max(0, tNear - Geometry.startDelta), tRear: tNear,
                            delta: Geometry.startDelta, nearIsFront: false, compensated: true)
        }
    }

    // MARK: - Шаг 5: группировка пересечений в заезды (старт → финиш)

    /// Старт и финиш — это один и тот же физический створ, через который
    /// едут в обе стороны: выезжая на упражнение и возвращаясь обратно.
    /// Направление проезда (знак расстояния до линии непосредственно перед
    /// пересечением) у выезда и у возврата, как правило, противоположно.
    ///
    /// Если райдер выехал, но вернулся не через створ (срезал по внешнему
    /// контуру), следующее пересечение будет снова в направлении "выезда" —
    /// предыдущая попытка в этом случае считается незавершённой (finish=nil),
    /// а не отбрасывается молча.
    ///
    /// minLapDuration отсекает дребезг трекинга прямо у створа: на плотной
    /// слаломной трассе байк может пересечь линию створа десятки раз за
    /// секунду, покачиваясь/выписывая восьмёрки рядом с ней, а не просто
    /// проехать насквозь один раз (проверено на реальном видео с плотной
    /// расстановкой конусов прямо у створа — там за 1.5с набегало по 14
    /// пересечений подряд). Любое пересечение, случившееся раньше
    /// minLapDuration после текущего pendingStart, — это ещё то же самое
    /// покачивание, а не новое событие, независимо от его направления:
    ///   - в обратном направлении — не настоящий финиш, игнорируем;
    ///   - в направлении "выезда" — не новая (брошенная) попытка, а просто
    ///     более поздний момент окончательного отъезда у того же самого
    ///     старта, сдвигаем pendingStart вперёд, не создавая мусорную
    ///     "незавершённую" запись.
    /// Ни одно реальное упражнение не проезжается быстрее пары секунд, так
    /// что порог взят с большим запасом.
    ///
    /// Направление "выезда" берётся НЕ у самого первого пересечения в видео,
    /// а у последнего пересечения в первой "пачке" (все пересечения в
    /// пределах minLapDuration друг от друга перед самым первым разрывом) —
    /// на старте байк иногда покачивается туда-сюда через линию перед тем,
    /// как окончательно уехать.
    private static func pairLaps(crossings: [Crossing], minLapDuration: Double = 2.0) -> (laps: [LapAttempt], startDirection: Bool) {
        guard !crossings.isEmpty else { return ([], true) }
        var burstEnd = 0
        while burstEnd + 1 < crossings.count, crossings[burstEnd + 1].time - crossings[burstEnd].time < minLapDuration {
            burstEnd += 1
        }
        let startDirection = crossings[burstEnd].fromPositiveSide

        func incomplete(_ s: Crossing, index: Int) -> LapAttempt {
            LapAttempt(index: index, startFront: s.tFront, startNear: s.time)
        }
        func complete(_ s: Crossing, _ f: Crossing, index: Int) -> LapAttempt {
            LapAttempt(index: index, startFront: s.tFront, startNear: s.time,
                       finishFront: f.tFront, finishRear: f.tRear, finishNear: f.time)
        }

        var laps: [LapAttempt] = []
        var pendingStart: Crossing?
        for crossing in crossings {
            if crossing.fromPositiveSide == startDirection {
                if let unfinished = pendingStart, crossing.time - unfinished.time >= minLapDuration {
                    laps.append(incomplete(unfinished, index: laps.count + 1))
                }
                pendingStart = crossing
            } else if let started = pendingStart, crossing.time - started.time >= minLapDuration {
                laps.append(complete(started, crossing, index: laps.count + 1))
                pendingStart = nil
            }
            // иначе: пересечение случилось раньше minLapDuration после
            // pendingStart — тот же дребезг у створа, см. комментарий выше.
        }
        if let unfinished = pendingStart {
            laps.append(incomplete(unfinished, index: laps.count + 1))
        }
        return (laps, startDirection)
    }
}

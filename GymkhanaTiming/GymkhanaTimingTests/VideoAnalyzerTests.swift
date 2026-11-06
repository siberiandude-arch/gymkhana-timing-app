import XCTest
@testable import GymkhanaTiming

/// Проверяет настоящий скомпилированный VideoAnalyzer (не python-имитацию)
/// на 4 реальных тестовых видео из TestVideos/, минуя камеру и интерфейс.
///
/// Тестовые видео сжаты до 960x540 для загрузки (оригинал — 1920x1080,
/// на котором калибровались координаты в gymkhana_timing_algorithm.py).
/// Калибровочные точки и все геометрически зависимые константы внутри
/// VideoAnalyzer (отступы ROI, min_area, area_thresh, ядра морфологии)
/// линейны/квадратичны от масштаба кадра и сами пересчитываются от
/// фактического naturalSize — поэтому здесь достаточно один раз
/// пересчитать сами калибровочные точки на тот же коэффициент 0.5.
final class VideoAnalyzerTests: XCTestCase {

    private struct Case {
        let videoName: String
        let p1: CGPoint
        let p2: CGPoint
        let referenceSeconds: Double
    }

    private let scale: CGFloat = 0.5

    private var cases: [Case] {
        [
            Case(videoName: "Глеб_Тула",
                 p1: CGPoint(x: 1120, y: 627).scaled(scale),
                 p2: CGPoint(x: 1317, y: 615).scaled(scale),
                 referenceSeconds: 64.7),
            Case(videoName: "0909",
                 p1: CGPoint(x: 1300, y: 612).scaled(scale),
                 p2: CGPoint(x: 1440, y: 590).scaled(scale),
                 referenceSeconds: 65.3),
            Case(videoName: "010837_стрипл",
                 p1: CGPoint(x: 1026, y: 774).scaled(scale),
                 p2: CGPoint(x: 1200, y: 754).scaled(scale),
                 referenceSeconds: 68.37),
            Case(videoName: "Заезд",
                 p1: CGPoint(x: 1117, y: 647).scaled(scale),
                 p2: CGPoint(x: 1313, y: 632).scaled(scale),
                 referenceSeconds: 62.14),
        ]
    }

    /// Python-версия на этих же 4 видео давала 0.05–0.55с расхождения с
    /// референсом табло; python-имитация текущих swift-констант — около
    /// 0.3с в среднем, максимум ~0.42с (см. README, раздел "Валидация").
    /// Здесь оставлен запас, чтобы тест ловил настоящую поломку алгоритма
    /// (сорвавшийся трекинг, неверный старт/финиш), а не платформенные
    /// отличия декодера H.264 между OpenCV и AVFoundation.
    private let maxAllowedError = 1.0
    /// Для правила «перед → зад» добавляется оценка базы (≈0.1–0.5с), допуск шире.
    private let maxAllowedRuleError = 2.0

    func testAccuracyAgainstReferenceVideos() async throws {
        var failures: [String] = []

        for testCase in cases {
            guard let url = Bundle(for: VideoAnalyzerTests.self)
                .url(forResource: testCase.videoName, withExtension: "mp4", subdirectory: "TestVideos") else {
                XCTFail("Не найдено тестовое видео \(testCase.videoName).mp4 в TestVideos/")
                continue
            }

            do {
                let started = Date()
                let output = try await VideoAnalyzer.analyze(videoURL: url, p1: testCase.p1, p2: testCase.p2)
                let elapsed = Date().timeIntervalSince(started)
                let laps = output.laps
                guard let lap = laps.first(where: { $0.finish != nil }),
                      let observed = lap.observedDuration,
                      let ff = lap.duration(for: .frontToFront),
                      let fr = lap.duration(for: .frontToRear) else {
                    failures.append("\(testCase.videoName): не найден завершённый заезд (попыток: \(laps.count))")
                    continue
                }
                let ref = testCase.referenceSeconds
                print(String(format: "[%@] анализ=%.1fс наблюдаемый=%.3fс (%+.3f) перед-перед=%.3fс (%+.3f) перед-зад=%.3fс (%+.3f) референс=%.2fс попыток=%d",
                             testCase.videoName, elapsed, observed, observed - ref, ff, ff - ref, fr, fr - ref, ref, laps.count))

                if abs(observed - ref) > maxAllowedError {
                    failures.append(String(format: "%@: наблюдаемый круг=%.3fс, референс=%.2fс, разница=%+.3fс (допуск ±%.1fс)",
                                            testCase.videoName, observed, ref, observed - ref, maxAllowedError))
                }
                if abs(fr - ref) > maxAllowedRuleError {
                    failures.append(String(format: "%@: круг (перед→зад)=%.3fс, референс=%.2fс, разница=%+.3fс (допуск ±%.1fс)",
                                            testCase.videoName, fr, ref, fr - ref, maxAllowedRuleError))
                }
            } catch {
                failures.append("\(testCase.videoName): VideoAnalyzer выбросил ошибку — \(error)")
            }
        }

        XCTAssertTrue(failures.isEmpty, "Расхождение с референсным временем табло превышает допуск:\n" + failures.joined(separator: "\n"))
    }
}

/// Конус на реальной записи оказался красно-оранжевым (оттенок ≈ 0–5°), и
/// детектор, настроенный на чисто оранжевый, не находил ничего. Здесь
/// синтетический кадр: два красных конуса с белой полоской (разрезает
/// конус на два куска) и широкое красное пятно-«приманка» (одежда).
final class ConeDetectorTests: XCTestCase {

    func testFindsRedStripedConesAndIgnoresWideBlob() throws {
        let size = CGSize(width: 1920, height: 1080)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.4, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            let red = UIColor(red: 205 / 255, green: 55 / 255, blue: 45 / 255, alpha: 1)
            func cone(apexX: CGFloat, apexY: CGFloat, baseY: CGFloat, halfWidth: CGFloat) {
                red.setFill()
                let path = UIBezierPath()
                path.move(to: CGPoint(x: apexX, y: apexY))
                path.addLine(to: CGPoint(x: apexX - halfWidth, y: baseY))
                path.addLine(to: CGPoint(x: apexX + halfWidth, y: baseY))
                path.close()
                path.fill()
                UIColor.white.setFill()
                ctx.fill(CGRect(x: apexX - halfWidth, y: (apexY + baseY) / 2, width: halfWidth * 2, height: 6))
            }
            cone(apexX: 500, apexY: 300, baseY: 380, halfWidth: 30)
            cone(apexX: 800, apexY: 290, baseY: 370, halfWidth: 30)
            red.setFill()
            ctx.fill(CGRect(x: 600, y: 330, width: 100, height: 30))
        }
        let cg = try XCTUnwrap(image.cgImage)

        let polygon = [CGPoint(x: 430, y: 250), CGPoint(x: 870, y: 250),
                       CGPoint(x: 870, y: 420), CGPoint(x: 430, y: 420)]
        let (left, right) = try ConeDetector.findConeBases(in: cg, polygon: polygon)

        XCTAssertEqual(left.x, 500, accuracy: 8)
        XCTAssertEqual(left.y, 380, accuracy: 8)
        XCTAssertEqual(right.x, 800, accuracy: 8)
        XCTAssertEqual(right.y, 370, accuracy: 8)
    }
}

private extension CGPoint {
    func scaled(_ scale: CGFloat) -> CGPoint {
        CGPoint(x: x * scale, y: y * scale)
    }
}

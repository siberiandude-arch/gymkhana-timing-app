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

    func testAccuracyAgainstReferenceVideos() async throws {
        var failures: [String] = []

        for testCase in cases {
            guard let url = Bundle(for: VideoAnalyzerTests.self)
                .url(forResource: testCase.videoName, withExtension: "mp4", subdirectory: "TestVideos") else {
                XCTFail("Не найдено тестовое видео \(testCase.videoName).mp4 в TestVideos/")
                continue
            }

            do {
                let result = try await VideoAnalyzer.analyze(videoURL: url, p1: testCase.p1, p2: testCase.p2)
                let diff = result.lap - testCase.referenceSeconds
                print(String(format: "[%@] круг=%.3fс старт=%.3fс финиш=%.3fс референс=%.2fс разница=%+.3fс пересечений=%d",
                             testCase.videoName, result.lap, result.start, result.finish,
                             testCase.referenceSeconds, diff, result.crossings.count))

                if abs(diff) > maxAllowedError {
                    failures.append(String(format: "%@: круг=%.3fс, референс=%.2fс, разница=%+.3fс (допуск ±%.1fс)",
                                            testCase.videoName, result.lap, testCase.referenceSeconds, diff, maxAllowedError))
                }
            } catch {
                failures.append("\(testCase.videoName): VideoAnalyzer выбросил ошибку — \(error)")
            }
        }

        XCTAssertTrue(failures.isEmpty, "Расхождение с референсным временем табло превышает допуск:\n" + failures.joined(separator: "\n"))
    }
}

private extension CGPoint {
    func scaled(_ scale: CGFloat) -> CGPoint {
        CGPoint(x: x * scale, y: y * scale)
    }
}

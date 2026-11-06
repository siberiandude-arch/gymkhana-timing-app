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

/// Клип заезда, выгруженный приложением с телефона (1920x1080, линия и
/// таймер вшиты в кадр, на борту — водяной знак конвертера). Разбор по
/// кадрам вручную (время в секундах от начала клипа):
///   старт: переднее колесо касается линии ≈0.95, заднее ≈1.45;
///   финиш: переднее колесо ≈69.7, заднее ≈70.25.
/// Трекер видит только ближнее к камере колесо: на старте это заднее
/// (1.52 с), на финише переднее (69.76 с) — совпадает с ручной разметкой.
/// Без поправки на второе колесо получается около секунды недобора против
/// правила «как лазер».
final class PhoneLapClipTests: XCTestCase {
    func testLaserTimingOnPhoneClip() async throws {
        guard let url = Bundle(for: PhoneLapClipTests.self)
            .url(forResource: "phone_lap", withExtension: "mp4", subdirectory: "TestVideos") else {
            XCTFail("Не найдено phone_lap.mp4 в TestVideos/")
            return
        }
        let p1 = CGPoint(x: 1012.5, y: 777)
        let p2 = CGPoint(x: 1205, y: 752.5)
        let started = Date()
        let output = try await VideoAnalyzer.analyze(videoURL: url, p1: p1, p2: p2)
        print(String(format: "[phone_lap] анализ=%.1fс пересечений=%d заездов=%d",
                     Date().timeIntervalSince(started), output.crossings.count, output.laps.count))
        for c in output.crossings {
            print(String(format: "[phone_lap] пересечение t=%.3f %@ перед=%.3f зад=%.3f Δ=%.3f ближнее=%@ поправка=%@",
                         c.time, c.isExit ? "выезд" : "возврат", c.tFront, c.tRear, c.delta,
                         c.nearIsFront ? "перед" : "зад", c.compensated ? "да" : "нет"))
        }
        for lap in output.laps {
            print(String(format: "[phone_lap] заезд %d старт(перед)=%.3f финиш(зад)=%@ круг(лазер)=%@ наблюдаемый=%@",
                         lap.index, lap.start,
                         lap.finish.map { String(format: "%.3f", $0) } ?? "—",
                         lap.duration.map { String(format: "%.3f", $0) } ?? "—",
                         lap.observedDuration.map { String(format: "%.3f", $0) } ?? "—"))
        }
        let lap = try XCTUnwrap(output.laps.first(where: { $0.finish != nil }), "нет завершённого заезда")
        // Ручная разметка: 69.3 с по лазеру (70.25 − 0.95). Сама разметка по
        // кадрам даёт ±0.15 с, поправка на колесо — типичное значение, так
        // что допуск ±0.6 с.
        let laser = try XCTUnwrap(lap.duration)
        XCTAssertEqual(laser, 69.3, accuracy: 0.6)
        XCTAssertEqual(output.laps.filter { $0.finish != nil }.count, 1)
    }
}

/// Второй клип с телефона (1280x720, линия и таймер вшиты в кадр). Байк
/// подъезжает к воротам, проезжает у правого конуса и останавливается
/// рядом с ним; в самом конце клипа камеру берут в руки, и кадр "прыгает"
/// (это не проезд!). Разбор по кадрам (секунды от начала клипа):
///   переднее колесо пересекает линию ≈66.5, заднее ≈66.9.
/// Приложение же остановило таймер на 69.74 — по скачку камеры.
final class PhoneLap2Tests: XCTestCase {
    func testFinishIsNotTriggeredByCameraJolt() async throws {
        guard let url = Bundle(for: PhoneLap2Tests.self)
            .url(forResource: "phone_lap2", withExtension: "mp4", subdirectory: "TestVideos") else {
            XCTFail("Не найдено phone_lap2.mp4 в TestVideos/")
            return
        }
        let p1 = CGPoint(x: 867, y: 410.8)
        let p2 = CGPoint(x: 956, y: 396.5)
        let started = Date()
        let output = try await VideoAnalyzer.analyze(videoURL: url, p1: p1, p2: p2)
        print(String(format: "[phone_lap2] анализ=%.1fс пересечений=%d заездов=%d",
                     Date().timeIntervalSince(started), output.crossings.count, output.laps.count))
        for c in output.crossings {
            print(String(format: "[phone_lap2] пересечение t=%.3f %@ перед=%.3f зад=%.3f Δ=%.3f ближнее=%@",
                         c.time, c.isExit ? "выезд" : "возврат", c.tFront, c.tRear, c.delta,
                         c.nearIsFront ? "перед" : "зад"))
        }
        for lap in output.laps {
            print(String(format: "[phone_lap2] заезд %d старт(перед)=%.3f финиш(зад)=%@",
                         lap.index, lap.start, lap.finish.map { String(format: "%.3f", $0) } ?? "—"))
        }
        let lap = try XCTUnwrap(output.laps.first(where: { $0.finish != nil }), "нет завершённого заезда")
        let finish = try XCTUnwrap(lap.finish)
        XCTAssertEqual(finish, 66.9, accuracy: 0.5)
        // Ровно один заезд: ни «заезда 2» из покачивания у створа после финиша,
        // ни скачка камеры в конце клипа.
        XCTAssertEqual(output.laps.filter { $0.finish != nil }.count, 1)
    }
}

/// Конусы бывают любого цвета, а асфальт — не всегда серый (под фонарями
/// он тёплый). Синтетические кадры: конусы разных цветов с белой полоской
/// (разрезает конус на два куска) и широкое пятно-«приманка» (одежда).
final class ConeDetectorTests: XCTestCase {

    private func makeFrame(asphalt: UIColor, cone: UIColor) throws -> CGImage {
        let size = CGSize(width: 1920, height: 1080)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            asphalt.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            func drawCone(apexX: CGFloat, apexY: CGFloat, baseY: CGFloat, halfWidth: CGFloat) {
                cone.setFill()
                let path = UIBezierPath()
                path.move(to: CGPoint(x: apexX, y: apexY))
                path.addLine(to: CGPoint(x: apexX - halfWidth, y: baseY))
                path.addLine(to: CGPoint(x: apexX + halfWidth, y: baseY))
                path.close()
                path.fill()
                UIColor.white.setFill()
                ctx.fill(CGRect(x: apexX - halfWidth, y: (apexY + baseY) / 2, width: halfWidth * 2, height: 6))
            }
            drawCone(apexX: 500, apexY: 300, baseY: 380, halfWidth: 30)
            drawCone(apexX: 800, apexY: 290, baseY: 370, halfWidth: 30)
            cone.setFill()
            ctx.fill(CGRect(x: 600, y: 330, width: 100, height: 30))
        }
        return try XCTUnwrap(image.cgImage)
    }

    private func assertFindsBothCones(asphalt: UIColor, cone: UIColor, file: StaticString = #filePath, line: UInt = #line) throws {
        let cg = try makeFrame(asphalt: asphalt, cone: cone)
        let polygon = [CGPoint(x: 430, y: 250), CGPoint(x: 870, y: 250),
                       CGPoint(x: 870, y: 420), CGPoint(x: 430, y: 420)]
        let (left, right) = try ConeDetector.findConeBases(in: cg, polygon: polygon)
        XCTAssertEqual(left.x, 500, accuracy: 8, file: file, line: line)
        XCTAssertEqual(left.y, 380, accuracy: 8, file: file, line: line)
        XCTAssertEqual(right.x, 800, accuracy: 8, file: file, line: line)
        XCTAssertEqual(right.y, 370, accuracy: 8, file: file, line: line)
    }

    private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
        UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    func testRedConesOnGrayAsphalt() throws {
        try assertFindsBothCones(asphalt: UIColor(white: 0.4, alpha: 1), cone: rgb(205, 55, 45))
    }

    func testOrangeConesOnGrayAsphalt() throws {
        try assertFindsBothCones(asphalt: UIColor(white: 0.45, alpha: 1), cone: rgb(255, 120, 20))
    }

    func testBlueConesOnGrayAsphalt() throws {
        try assertFindsBothCones(asphalt: UIColor(white: 0.35, alpha: 1), cone: rgb(30, 100, 210))
    }

    func testYellowConesOnWarmAsphalt() throws {
        try assertFindsBothCones(asphalt: rgb(120, 100, 80), cone: rgb(245, 205, 40))
    }

    func testGreenConesOnDarkAsphalt() throws {
        try assertFindsBothCones(asphalt: UIColor(white: 0.2, alpha: 1), cone: rgb(40, 190, 60))
    }
}

private extension CGPoint {
    func scaled(_ scale: CGFloat) -> CGPoint {
        CGPoint(x: x * scale, y: y * scale)
    }
}

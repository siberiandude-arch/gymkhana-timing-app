import CoreGraphics
import Foundation

/// Находит основания двух конусов (там, где они касаются асфальта) в
/// области кадра, обведённой пользователем от руки (замкнутый контур) — по цвету: конусы ярко-
/// оранжевые, асфальт/трава/небо — нет. Это помощник поверх ручной
/// разметки, а не замена: если не нашёл — райдер просто ставит точки сам.
///
/// Основание берём специально (не верхушку) — трекер в VideoAnalyzer
/// отслеживает нижнюю точку силуэта байка (колесо на асфальте), и линия
/// старта-финиша должна быть в той же плоскости, иначе из-за ракурса
/// камеры возможен ложный ранний старт (проверено на реальном видео).
enum ConeDetector {
    enum DetectionError: Error {
        case regionTooSmall
        case bitmapCreationFailed
        case notEnoughCones(found: Int)
    }

    /// `polygon` — контур обводки в пиксельных координатах кадра; он
    /// считается замкнутым (последняя точка соединяется с первой).
    static func findConeBases(in image: CGImage, polygon: [CGPoint]) throws -> (left: CGPoint, right: CGPoint) {
        guard polygon.count >= 3 else { throw DetectionError.regionTooSmall }
        let xs = polygon.map { $0.x }, ys = polygon.map { $0.y }
        let region = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                            width: (xs.max() ?? 0) - (xs.min() ?? 0),
                            height: (ys.max() ?? 0) - (ys.min() ?? 0))
        // Пальцем контур ведут неточно — он нередко режет конус по краю или
        // проходит чуть выше основания. Даём запас: обводка толстеет на
        // ~10% меньшей стороны (и область поиска растёт на столько же),
        // иначе у "обрезанного" конуса пропадает основание.
        let margin = max(4.0, 0.1 * Double(min(region.width, region.height)))
        let x0 = max(0, Int((region.minX - margin).rounded(.down)))
        let y0 = max(0, Int((region.minY - margin).rounded(.down)))
        let x1 = min(image.width, Int((region.maxX + margin).rounded(.up)))
        let y1 = min(image.height, Int((region.maxY + margin).rounded(.up)))
        let w = x1 - x0, h = y1 - y0
        guard w > 8, h > 8 else { throw DetectionError.regionTooSmall }

        guard let cropped = image.cropping(to: CGRect(x: x0, y: y0, width: w, height: h)) else {
            throw DetectionError.bitmapCreationFailed
        }

        // Маска внутренности контура: рисуем полигон белым в 8-битный
        // градационный буфер (строка 0 — верх кадра, как и у пикселей ниже).
        var inside = [UInt8](repeating: 0, count: w * h)
        let gray = CGColorSpaceCreateDeviceGray()
        let insideOK = inside.withUnsafeMutableBytes { raw -> Bool in
            guard let maskCtx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            maskCtx.translateBy(x: 0, y: CGFloat(h))
            maskCtx.scaleBy(x: 1, y: -1)
            maskCtx.setFillColor(gray: 1, alpha: 1)
            maskCtx.setStrokeColor(gray: 1, alpha: 1)
            maskCtx.setLineWidth(CGFloat(margin * 2))
            maskCtx.setLineJoin(.round)
            maskCtx.beginPath()
            for (i, pt) in polygon.enumerated() {
                let q = CGPoint(x: pt.x - CGFloat(x0), y: pt.y - CGFloat(y0))
                if i == 0 { maskCtx.move(to: q) } else { maskCtx.addLine(to: q) }
            }
            maskCtx.closePath()
            maskCtx.drawPath(using: .fillStroke)
            return true
        }
        guard insideOK else { throw DetectionError.bitmapCreationFailed }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw DetectionError.bitmapCreationFailed
        }
        // CGContext по умолчанию рисует снизу вверх; переворачиваем, чтобы
        // строка 0 в pixels соответствовала верху кадра — так же, как везде
        // в VideoAnalyzer (иначе найдём верхушку конуса вместо основания).
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))

        var mask = [Bool](repeating: false, count: w * h)
        pixels.withUnsafeBufferPointer { buf in
            for i in 0..<(w * h) {
                let r = Int(buf[i * 4]), g = Int(buf[i * 4 + 1]), b = Int(buf[i * 4 + 2])
                mask[i] = inside[i] > 127 && isConeOrange(r: r, g: g, b: b)
            }
        }

        // Конус часто разрезан светоотражающей полоской или бликом на
        // несколько кусков — склеиваем близкие куски расширением маски,
        // но сами пиксели конуса (и его основание) берём из исходной.
        let radius = max(2, image.width / 400)
        let dilated = dilate(mask: mask, width: w, height: h, radius: radius)

        let minArea = max(12, Int((60.0 * pow(Double(image.width) / 1920.0, 2)).rounded()))
        let rawComponents = findComponents(mask: dilated, width: w, height: h, minArea: 1)
        var cones: [Cone] = []
        for comp in rawComponents {
            let own = comp.filter { mask[$0.1 * w + $0.0] }
            guard own.count >= minArea else { continue }
            let xs = own.map { $0.0 }, ys = own.map { $0.1 }
            let bw = (xs.max() ?? 0) - (xs.min() ?? 0) + 1
            let bh = (ys.max() ?? 0) - (ys.min() ?? 0) + 1
            // конус — выше, чем шире; широкие пятна — это не конус
            // (одежда, наклейки)
            guard Double(bh) >= Double(bw) * 0.8 else { continue }
            cones.append(Cone(area: own.count, width: bw, height: bh, base: baseCenter(of: own)))
        }
        guard cones.count >= 2 else { throw DetectionError.notEnoughCones(found: cones.count) }

        // Лучшая пара: два крупных конуса похожего размера, стоящие рядом
        // по высоте кадра и не слипшиеся друг с другом.
        var best: (score: Double, a: Cone, b: Cone)?
        let top = cones.sorted { $0.area > $1.area }.prefix(8)
        let list = Array(top)
        for i in 0..<list.count {
            for j in (i + 1)..<list.count {
                let c1 = list[i], c2 = list[j]
                let maxH = Double(max(c1.height, c2.height))
                let minH = Double(min(c1.height, c2.height))
                let dx = abs(Double(c1.base.x - c2.base.x))
                let dy = abs(Double(c1.base.y - c2.base.y))
                guard dx >= Double(max(c1.width, c2.width)) * 1.5, dy <= maxH * 2 else { continue }
                let score = Double(min(c1.area, c2.area)) * (minH / maxH)
                if best == nil || score > best!.score { best = (score, c1, c2) }
            }
        }
        guard let pair = best else { throw DetectionError.notEnoughCones(found: cones.count) }

        let ordered = [pair.a.base, pair.b.base].sorted { $0.x < $1.x }
        let left = CGPoint(x: ordered[0].x + CGFloat(x0), y: ordered[0].y + CGFloat(y0))
        let right = CGPoint(x: ordered[1].x + CGFloat(x0), y: ordered[1].y + CGFloat(y0))
        return (left, right)
    }

    private struct Cone {
        let area: Int
        let width: Int
        let height: Int
        let base: CGPoint
    }

    /// Пластик конуса: от красного (−15°) до оранжевого (45°), насыщенный и
    /// не тёмный. Сначала я делал только оранжевый (10–45°), но на реальной
    /// записи конусы оказались красно-оранжевыми (оттенок ≈ 0–5°) и не
    /// находились вовсе. Красная одежда тоже попадает в маску, но отсекается
    /// формой (конус выше, чем шире) и выбором пары похожего размера.
    /// (r — максимальный канал, оттенок выражается через g−b и r−min(g,b).)
    private static func isConeOrange(r: Int, g: Int, b: Int) -> Bool {
        guard r >= 80, r >= g, r >= b else { return false }
        let delta = r - min(g, b)
        guard delta * 255 >= r * 120 else { return false }   // насыщенность ≥ 0.47
        return (g - b) * 4 <= 3 * delta && (b - g) * 4 <= delta
    }

    private static func dilate(mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                let ya = max(0, y - radius), yb = min(height - 1, y + radius)
                let xa = max(0, x - radius), xb = min(width - 1, x + radius)
                for yy in ya...yb {
                    for xx in xa...xb { out[yy * width + xx] = true }
                }
            }
        }
        return out
    }

    private static func findComponents(mask: [Bool], width: Int, height: Int, minArea: Int) -> [[(Int, Int)]] {
        var visited = [Bool](repeating: false, count: width * height)
        var result: [[(Int, Int)]] = []
        var stack: [(Int, Int)] = []
        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                if !mask[idx] || visited[idx] { continue }
                var pixels: [(Int, Int)] = []
                stack.removeAll(keepingCapacity: true)
                stack.append((x, y))
                visited[idx] = true
                while let (cx, cy) = stack.popLast() {
                    pixels.append((cx, cy))
                    if cx > 0, mask[cy * width + cx - 1], !visited[cy * width + cx - 1] {
                        visited[cy * width + cx - 1] = true
                        stack.append((cx - 1, cy))
                    }
                    if cx < width - 1, mask[cy * width + cx + 1], !visited[cy * width + cx + 1] {
                        visited[cy * width + cx + 1] = true
                        stack.append((cx + 1, cy))
                    }
                    if cy > 0, mask[(cy - 1) * width + cx], !visited[(cy - 1) * width + cx] {
                        visited[(cy - 1) * width + cx] = true
                        stack.append((cx, cy - 1))
                    }
                    if cy < height - 1, mask[(cy + 1) * width + cx], !visited[(cy + 1) * width + cx] {
                        visited[(cy + 1) * width + cx] = true
                        stack.append((cx, cy + 1))
                    }
                }
                if pixels.count >= minArea {
                    result.append(pixels)
                }
            }
        }
        return result
    }

    /// Нижняя точка конуса — там, где он касается асфальта: центр по X
    /// среди пикселей в нижних ~10% высоты компонента, а не просто самый
    /// нижний пиксель (он может быть одиночным шумовым выбросом).
    private static func baseCenter(of pixels: [(Int, Int)]) -> CGPoint {
        let maxY = pixels.map { $0.1 }.max() ?? 0
        let minY = pixels.map { $0.1 }.min() ?? 0
        let band = max(1, (maxY - minY) / 10)
        let bottomPixels = pixels.filter { $0.1 >= maxY - band }
        let avgX = bottomPixels.reduce(0) { $0 + $1.0 } / max(1, bottomPixels.count)
        return CGPoint(x: Double(avgX), y: Double(maxY))
    }
}

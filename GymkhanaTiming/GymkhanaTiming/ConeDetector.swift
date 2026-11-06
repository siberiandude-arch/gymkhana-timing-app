import CoreGraphics
import Foundation

/// Находит основания двух конусов (там, где они касаются асфальта) в
/// области кадра, обведённой пользователем от руки (замкнутый контур).
/// Цвет конуса не важен: ищется всё, что по оттенку заметно отличается
/// от асфальта, затем отбираются фигуры формы конуса (выше, чем шире) и
/// выбирается пара похожего размера. Если не нашёл — райдеру предлагается
/// обвести точнее или выбрать другой кадр.
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
        // Здесь переворот НЕ нужен: у bitmap-контекста CoreGraphics первая
        // строка в памяти — это верх картинки, даже если система координат
        // идёт снизу вверх. Раньше здесь стоял переворот (по ошибке), и
        // детектор видел кадр вверх ногами: основание конуса находилось как
        // его вершина, линия ложилась не туда. Маска контура выше как раз
        // рисуется с переворотом — она задана в координатах "сверху вниз".
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw DetectionError.bitmapCreationFailed }

        // Конусы бывают любого цвета, поэтому ищем не конкретный цвет, а то,
        // что заметно отличается от асфальта: берём типичный (медианный)
        // оттенок внутри обводки — там почти везде асфальт — и помечаем
        // пиксели, чей оттенок от него далеко. Оттенок — это пара
        // (R−G, (R+G)/2−B): она почти не зависит от яркости, так что тени
        // и белая разметка (тот же оттенок, что у асфальта) не мешают.
        let count = w * h
        var chromaU = [Int16](repeating: 0, count: count)
        var chromaV = [Int16](repeating: 0, count: count)
        var brightness = [UInt8](repeating: 0, count: count)
        var histU = [Int](repeating: 0, count: 511)
        var histV = [Int](repeating: 0, count: 511)
        var insideCount = 0
        pixels.withUnsafeBufferPointer { buf in
            for i in 0..<count {
                let r = Int(buf[i * 4]), g = Int(buf[i * 4 + 1]), b = Int(buf[i * 4 + 2])
                let u = r - g
                let v = (r + g) / 2 - b
                chromaU[i] = Int16(u)
                chromaV[i] = Int16(v)
                brightness[i] = UInt8(max(r, g, b))
                if inside[i] > 127 {
                    histU[u + 255] += 1
                    histV[v + 255] += 1
                    insideCount += 1
                }
            }
        }
        guard insideCount > 0 else { throw DetectionError.regionTooSmall }
        let medianU = Double(histogramMedian(histU, total: insideCount) - 255)
        let medianV = Double(histogramMedian(histV, total: insideCount) - 255)

        // Типичное отклонение оттенка в самом асфальте (на тонированном
        // фонарями асфальте оно больше) — порог не должен быть меньше.
        var histDist = [Int](repeating: 0, count: 512)
        var distance = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let du = Double(chromaU[i]) - medianU, dv = Double(chromaV[i]) - medianV
            let d = Float((du * du + dv * dv).squareRoot())
            distance[i] = d
            if inside[i] > 127 { histDist[min(511, Int(d))] += 1 }
        }
        let typicalDeviation = Double(histogramMedian(histDist, total: insideCount))
        let threshold = Float(max(45.0, 4.0 * typicalDeviation))

        var mask = [Bool](repeating: false, count: count)
        for i in 0..<count {
            mask[i] = inside[i] > 127 && brightness[i] >= 50 && distance[i] >= threshold
        }

        // Конус часто разрезан светоотражающей полоской или бликом на
        // несколько кусков, поэтому склеиваем куски расширением маски:
        // слабо по горизонтали и заметно по вертикали (полоски лежат друг
        // над другом). Сами пиксели конуса и его основание берём из
        // исходной маски.
        let radius = max(2, image.width / 400)
        let verticalRadius = max(radius, Int(Double(image.height) * 0.03))
        let dilated = dilate(mask: mask, width: w, height: h, radiusX: radius, radiusY: verticalRadius)

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

    private static func histogramMedian(_ hist: [Int], total: Int) -> Int {
        var acc = 0
        for (value, n) in hist.enumerated() {
            acc += n
            if acc * 2 >= total { return value }
        }
        return hist.count / 2
    }

    /// Расширение маски прямоугольным окном (2rx+1)×(2ry+1) за два прохода
    /// со скользящей суммой — быстро и при большом окне.
    private static func dilate(mask: [Bool], width: Int, height: Int, radiusX: Int, radiusY: Int) -> [Bool] {
        var horizontal = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            var prefix = [Int](repeating: 0, count: width + 1)
            for x in 0..<width { prefix[x + 1] = prefix[x] + (mask[y * width + x] ? 1 : 0) }
            for x in 0..<width {
                let lo = max(0, x - radiusX), hi = min(width - 1, x + radiusX)
                horizontal[y * width + x] = prefix[hi + 1] - prefix[lo] > 0
            }
        }
        var out = [Bool](repeating: false, count: width * height)
        for x in 0..<width {
            var prefix = [Int](repeating: 0, count: height + 1)
            for y in 0..<height { prefix[y + 1] = prefix[y] + (horizontal[y * width + x] ? 1 : 0) }
            for y in 0..<height {
                let lo = max(0, y - radiusY), hi = min(height - 1, y + radiusY)
                out[y * width + x] = prefix[hi + 1] - prefix[lo] > 0
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

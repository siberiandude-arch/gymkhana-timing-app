import CoreGraphics

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
        let x0 = max(0, Int(region.minX.rounded(.down)))
        let y0 = max(0, Int(region.minY.rounded(.down)))
        let x1 = min(image.width, Int(region.maxX.rounded(.up)))
        let y1 = min(image.height, Int(region.maxY.rounded(.up)))
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
            maskCtx.beginPath()
            for (i, pt) in polygon.enumerated() {
                let q = CGPoint(x: pt.x - CGFloat(x0), y: pt.y - CGFloat(y0))
                if i == 0 { maskCtx.move(to: q) } else { maskCtx.addLine(to: q) }
            }
            maskCtx.closePath()
            maskCtx.fillPath()
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

        let minArea = max(20, (w * h) / 400)
        let components = findComponents(mask: mask, width: w, height: h, minArea: minArea)
        guard components.count >= 2 else {
            throw DetectionError.notEnoughCones(found: components.count)
        }
        let top2 = components.sorted { $0.count > $1.count }.prefix(2)
        let baseCenters = top2.map { baseCenter(of: $0) }
        let ordered = baseCenters.sorted { $0.x < $1.x }
        let left = CGPoint(x: ordered[0].x + CGFloat(x0), y: ordered[0].y + CGFloat(y0))
        let right = CGPoint(x: ordered[1].x + CGFloat(x0), y: ordered[1].y + CGFloat(y0))
        return (left, right)
    }

    /// Эмпирический порог для ярко-оранжевого пластика конуса на асфальте/
    /// траве/небе — не точная цветовая модель, но достаточно для контраста
    /// с типичным фоном площадки.
    private static func isConeOrange(r: Int, g: Int, b: Int) -> Bool {
        r > 140 && r > g + 35 && g > b + 5 && b < 110
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

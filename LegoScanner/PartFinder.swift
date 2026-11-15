import UIKit
import Vision

/// Ein Bereich im Bild, in dem ein Teil liegen könnte.
struct FoundRegion {
    let box: CGRect       // normiert auf das untersuchte Bild, Ursprung oben links
    let cropRect: CGRect  // normiert, Ausschnitt mit Rand, der an Brickognize geht
    let image: UIImage    // dieser Ausschnitt
}

/// Zerlegt ein Bild in einzelne Teile, damit Brickognize (kann nur ein Teil pro Bild) jedes einzeln erkennt.
/// Zwei Verfahren ergänzen sich (gemessen an einem Foto mit 4 Teilen auf Holz):
/// Vision-Freistellen findet die auffälligen Teile (3 von 4), der Farbunterschied zum Tisch den Rest
/// (kleine, flache Teile). Was davon kein LEGO ist (Holzmaserung), sortiert Brickognize später aus.
enum PartFinder {
    // Kalibrierung:
    static let colorThreshold = 3000.0 // Farbabstand zur Tischfarbe (Redmean²), ab dem ein Pixel "nicht Tisch" ist
    static let minArea = 0.004         // kleinster Fleck: 0,4 % des Bildes
    static let maxArea = 0.5           // größer = kein Teil (z. B. Lichtverlauf, Tischset)
    static let maxParts = 8

    /// `image` darf groß sein (4K-Ausschnitt): gesucht wird auf einer verkleinerten Kopie (schnell),
    /// ausgeschnitten aus dem Original (kleine Teile behalten genug Pixel für Brickognize).
    static func find(in image: CGImage) -> [FoundRegion] {
        let started = Date.now
        let detect = downscaled(image, maxSide: 1024)
        var boxes = visionInstances(detect)
        let vision = boxes.count, blobs = colorBlobs(detect)
        for blob in blobs where !boxes.contains(where: { overlap($0, blob) > 0.2 }) {
            boxes.append(blob)
        }
        #if DEBUG
        print(String(format: "PARTS Vision %d, Farbflecken %d, zusammen %d, %.2f s, Ausschnitt %dx%d",
                     vision, blobs.count, boxes.count, Date.now.timeIntervalSince(started), image.width, image.height))
        #endif
        return boxes.prefix(maxParts).compactMap { crop(image, box: $0) }
    }

    private static func downscaled(_ image: CGImage, maxSide: Int) -> CGImage {
        let scale = Double(maxSide) / Double(max(image.width, image.height))
        guard scale < 1 else { return image }
        let width = Int(Double(image.width) * scale), height = Int(Double(image.height) * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Anteil der kleineren Fläche, der mit der anderen überlappt (0…1).
    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        return (inter.width * inter.height) / max(1e-9, min(a.width * a.height, b.width * b.height))
    }

    /// Vision "Motiv freistellen": ein Rahmen pro gefundenem Objekt.
    private static func visionInstances(_ image: CGImage) -> [CGRect] {
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        guard (try? handler.perform([request])) != nil, let result = request.results?.first else { return [] }
        return result.allInstances.sorted().compactMap { instance in
            guard let mask = try? result.generateScaledMaskForImage(forInstances: [instance], from: handler) else { return nil }
            CVPixelBufferLockBaseAddress(mask, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
            let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask)
            let row = CVPixelBufferGetBytesPerRow(mask) / MemoryLayout<Float32>.size
            guard let pixels = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: Float32.self) else { return nil }
            var minX = width, minY = height, maxX = 0, maxY = 0
            for y in stride(from: 0, to: height, by: 2) {
                for x in stride(from: 0, to: width, by: 2) where pixels[y * row + x] > 0.5 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard minX < maxX, minY < maxY else { return nil }
            let box = CGRect(x: Double(minX) / Double(width), y: Double(minY) / Double(height),
                             width: Double(maxX - minX) / Double(width), height: Double(maxY - minY) / Double(height))
            return box.width * box.height < maxArea ? box : nil
        }
    }

    /// Flecken, die sich deutlich von der Tischfarbe (Bildrand) abheben.
    // ponytail: einfache Schwelle + "Öffnen" gegen Maserung; bei sehr unruhigem Untergrund kommen mehr
    // Fehlflecken, die Brickognize dann aussortiert (kostet nur Anfragen, zählt nichts falsch).
    private static func colorBlobs(_ image: CGImage) -> [CGRect] {
        let n = 128
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return [] }
        func rgb(_ i: Int) -> SIMD3<Double> { SIMD3(Double(pixels[i * 4]), Double(pixels[i * 4 + 1]), Double(pixels[i * 4 + 2])) }

        // Tischfarbe = Median des Bildrands
        let border = (0..<n).flatMap { i in [i, (n - 1) * n + i, i * n, i * n + n - 1] }.map(rgb)
        func median(_ c: Int) -> Double { border.map { $0[c] }.sorted()[border.count / 2] }
        let table = SIMD3(median(0), median(1), median(2))

        var mask = (0..<n * n).map { colorDistance(rgb($0), table) > colorThreshold }
        // "Öffnen" (erst schrumpfen, dann wachsen): entfernt dünne Linien wie Holzmaserung
        func morph(_ m: [Bool], erode: Bool) -> [Bool] {
            (0..<n * n).map { i in
                let x = i % n, y = i / n
                let around = [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)].map { dx, dy -> Bool in
                    let nx = x + dx, ny = y + dy
                    return nx >= 0 && ny >= 0 && nx < n && ny < n && m[ny * n + nx]
                }
                return erode ? around.allSatisfy { $0 } : around.contains(true)
            }
        }
        mask = morph(morph(mask, erode: true), erode: false)

        var seen = [Bool](repeating: false, count: n * n)
        var blobs: [CGRect] = []
        for start in 0..<n * n where mask[start] && !seen[start] {
            var stack = [start], area = 0, touchesEdge = false
            var minX = n, minY = n, maxX = 0, maxY = 0
            seen[start] = true
            while let i = stack.popLast() {
                let x = i % n, y = i / n
                area += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                if x == 0 || y == 0 || x == n - 1 || y == n - 1 { touchesEdge = true }
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < n, ny < n, mask[ny * n + nx], !seen[ny * n + nx] else { continue }
                    seen[ny * n + nx] = true
                    stack.append(ny * n + nx)
                }
            }
            let share = Double(area) / Double(n * n)
            // Flecken am Rand sind meist Tischkante/Tischset oder nur halb im Rahmen liegende Teile
            guard !touchesEdge, share >= minArea, share <= maxArea else { continue }
            blobs.append(CGRect(x: Double(minX) / Double(n), y: Double(minY) / Double(n),
                                width: Double(maxX - minX + 1) / Double(n), height: Double(maxY - minY + 1) / Double(n)))
        }
        return blobs
    }

    /// Ausschnitt mit 15 % Rand, damit Brickognize das ganze Teil sieht und die Farbmessung den Tisch kennt.
    private static func crop(_ image: CGImage, box: CGRect) -> FoundRegion? {
        let pad = max(box.width, box.height) * 0.15
        let cropRect = box.insetBy(dx: -pad, dy: -pad).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixels = CGRect(x: cropRect.minX * Double(image.width), y: cropRect.minY * Double(image.height),
                            width: cropRect.width * Double(image.width), height: cropRect.height * Double(image.height)).integral
        guard let cropped = image.cropping(to: pixels) else { return nil }
        return FoundRegion(box: box, cropRect: cropRect, image: UIImage(cgImage: cropped))
    }
}

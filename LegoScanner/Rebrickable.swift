import simd
import SwiftUI

struct LegoColor: Identifiable, Hashable {
    let id: Int            // Rebrickable-Farb-ID
    let name: String
    let rgb: SIMD3<Double> // sRGB 0…255
    let isTrans: Bool
    let bricklinkID: Int?
    var sets = 0           // in wie vielen Sets das Teil in dieser Farbe vorkommt (pro Teil gesetzt)

    var swatch: Color { Color(red: rgb.x / 255, green: rgb.y / 255, blue: rgb.z / 255) }

    /// "Redmean"-Abstand: einfache, wahrnehmungsnahe RGB-Distanz.
    func distance(to c: SIMD3<Double>) -> Double {
        let r = (rgb.x + c.x) / 2, d = rgb - c
        return (2 + r / 256) * d.x * d.x + 4 * d.y * d.y + (2 + (255 - r) / 256) * d.z * d.z
    }
}

/// Farbe des Teils (sRGB 0…255). Hintergrundfarbe = Bildrand (der Tisch im Scanfeld); gemessen werden
/// nur Pixel im Rahmen, die sich deutlich davon abheben. Median, damit Glanzlicht und Schatten wenig zählen.
func partColor(in image: CGImage, box: CGRect) -> SIMD3<Double>? {
    let n = 64
    var pixels = [UInt8](repeating: 0, count: n * n * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        return true
    }
    guard drawn else { return nil }

    func rgb(_ x: Int, _ y: Int) -> SIMD3<Double> { // y = 0 ist die oberste Zeile
        let i = (y * n + x) * 4
        return SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
    }
    func median(_ colors: [SIMD3<Double>]) -> SIMD3<Double> {
        func channel(_ c: Int) -> Double { colors.map { $0[c] }.sorted()[colors.count / 2] }
        return SIMD3(channel(0), channel(1), channel(2))
    }
    func region(_ r: CGRect) -> [SIMD3<Double>] {
        let x0 = max(0, Int(r.minX * Double(n))), x1 = min(n, Int(r.maxX * Double(n)) + 1)
        let y0 = max(0, Int(r.minY * Double(n))), y1 = min(n, Int(r.maxY * Double(n)) + 1)
        guard x0 < x1, y0 < y1 else { return [] }
        return (y0..<y1).flatMap { y in (x0..<x1).map { x in rgb(x, y) } }
    }

    let background = median((0..<n).flatMap { i in [rgb(i, 0), rgb(i, n - 1), rgb(0, i), rgb(n - 1, i)] })
    let inBox = region(box)
    // Kalibrierung: ab diesem RGB-Abstand zur Tischfarbe gehört ein Pixel zum Teil.
    let partPixels = inBox.filter { simd_length($0 - background) > 45 }
    // Teil hebt sich kaum vom Tisch ab (z. B. Tan auf Holz) → wie früher die Rahmenmitte nehmen.
    let chosen = partPixels.count >= max(8, inBox.count / 10)
        ? partPixels : region(box.insetBy(dx: box.width * 0.3, dy: box.height * 0.3))
    return chosen.isEmpty ? nil : median(chosen)
}

extension Array where Element == LegoColor {
    /// Wahrscheinlichste deckende Farbe: nah an der Messung UND häufig für dieses Teil.
    /// Transparente Farben nur per Hand wählbar.
    func best(for rgb: SIMD3<Double>) -> LegoColor? {
        // Kalibrierung: wie stark Kamera/Licht die Farbe verfälschen (größer = Häufigkeit zählt mehr).
        // Mit 2500 gewinnt bei der gelben Platte 3795 "Yellow" (533 Sets) gegen das übersättigt
        // gemessene "Vibrant Yellow" (12 Sets), ohne Grau/Schwarz/Weiß zu verwechseln.
        let cameraNoise = 2500.0
        return filter { !$0.isTrans }.max {
            log(Double($0.sets + 1)) - $0.distance(to: rgb) / cameraNoise <
            log(Double($1.sets + 1)) - $1.distance(to: rgb) / cameraNoise
        }
    }
}

/// Farbdaten aus colors.json (gebaut von tools/build_colors.py aus den Rebrickable-Downloads).
/// Mitgeliefert im Bundle; neuere Fassungen lädt `refresh()` vom GitHub-Repo nach.
@MainActor
enum Rebrickable {
    // Wird jede Woche vom GitHub-Job (.github/workflows/colors.yml) aktualisiert.
    static let remoteURL = URL(string: "https://raw.githubusercontent.com/timmbrockerhoff/LegoScanner/main/LegoScanner/colors.json")!

    private typealias ColorData = (updated: String, colors: [Int: LegoColor], parts: [String: [Int]])

    private static let cacheURL = URL.applicationSupportDirectory.appending(path: "colors.json")
    private static let etagKey = "colorsETag"

    /// Die neuere von zwischengespeicherter und mitgelieferter Datei.
    private static var data: ColorData = {
        let cached = (try? Data(contentsOf: cacheURL)).flatMap(parse)
        let bundled = Bundle.main.url(forResource: "colors", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }.flatMap(parse)
        return [cached, bundled].compactMap { $0 }.max { $0.updated < $1.updated } ?? ("", [:], [:])
    }()

    /// Farben, in denen es das Teil gibt, häufigste zuerst.
    // ponytail: nimmt an, dass BrickLink- und Rebrickable-Teilenummer gleich sind (meistens so).
    // Wenn nicht, gibt es [] → dann Rebrickables parts.csv/part_relationships mit in die Datei nehmen.
    static func colors(forPart part: String) -> [LegoColor] {
        let flat = data.parts[part] ?? []
        return stride(from: 0, to: flat.count - 1, by: 2).compactMap { i in
            data.colors[flat[i]].map { var c = $0; c.sets = flat[i + 1]; return c }
        }
    }

    /// Lädt eine neuere Farbdatei, falls sich seit dem letzten Mal etwas geändert hat (ETag),
    /// und nimmt sie sofort in Betrieb. Offline, 304 oder kaputte Datei → alte Daten bleiben.
    static func refresh() async {
        var request = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalCacheData)
        if let etag = UserDefaults.standard.string(forKey: etagKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        guard let (body, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let fresh = parse(body), fresh.updated >= data.updated else { return }

        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? body.write(to: cacheURL, options: .atomic)
        UserDefaults.standard.set(http.value(forHTTPHeaderField: "ETag"), forKey: etagKey)
        data = fresh
    }

    private nonisolated static func parse(_ body: Data) -> ColorData? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let updated = json["updated"] as? String,
              let rawColors = json["colors"] as? [String: [Any]],
              let parts = json["parts"] as? [String: [Int]] else { return nil }

        var colors: [Int: LegoColor] = [:]
        for (key, v) in rawColors {
            guard let id = Int(key), v.count == 4, let name = v[0] as? String, let hex = v[1] as? String,
                  let isTrans = v[2] as? Bool, let rgb = UInt32(hex, radix: 16) else { continue }
            colors[id] = LegoColor(id: id, name: name,
                                   rgb: SIMD3(Double((rgb >> 16) & 0xFF), Double((rgb >> 8) & 0xFF), Double(rgb & 0xFF)),
                                   isTrans: isTrans, bricklinkID: v[3] as? Int)
        }
        return colors.isEmpty || parts.isEmpty ? nil : (updated, colors, parts)
    }
}

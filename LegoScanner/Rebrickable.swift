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

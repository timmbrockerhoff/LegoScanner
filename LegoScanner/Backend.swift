import UIKit

/// Ein Teil, wie das eigene Backend es erkannt hat (dort: Claude + BrickLink-Farben).
struct DetectedPart: Decodable, Hashable {
    struct Box: Decodable, Hashable { let x, y, w, h: Double }

    let partNo: String      // BrickLink-Teilenummer
    let name: String
    let colorName: String   // BrickLink-Farbname
    let colorId: Int?       // BrickLink-Farb-ID
    let confidence: Double  // 0–1, nur das Teil (Form)
    let box: Box            // Anteile 0–1 des gesendeten Bildes, Ursprung oben links

    var rect: CGRect { CGRect(x: box.x, y: box.y, width: box.w, height: box.h) }
    var label: String { "\(name) · \(colorName)" }
}

enum Backend {
    /// Adresse und App-Schlüssel aus der Info.plist (`BackendURL`, `AppKey` aus Secrets.xcconfig).
    static let url = URL(string: Bundle.main.object(forInfoDictionaryKey: "BackendURL") as? String ?? "")!
    // ponytail: gemeinsamer App-Schlüssel steckt im App-Binary, nur gegen Zufallszugriffe. Vor dem App Store: App Attest.
    static let appKey = Bundle.main.object(forInfoDictionaryKey: "AppKey") as? String ?? ""

    // Kalibrierung: darunter wird nichts angezeigt, ab `sureScore` automatisch gezählt, dazwischen nachgefragt.
    static let minScore = 0.5
    // 0.9 statt 0.8: Claude gibt 80–85 % auch bei geratener Nummer. Gilt nur fürs Teil, die Farbe ist in Kiste und Set änderbar.
    static let sureScore = 0.9

    /// Foto → erkannte LEGO-Teile (leere Liste = kein LEGO im Bild).
    /// `sets`: Sets, die der Nutzer gerade zusammensucht. Das Backend gibt Claude deren Teileliste als Kandidaten.
    static func identify(_ image: UIImage, sets: [String] = []) async throws -> [DetectedPart] {
        // Kosten: Bild-Tokens ≈ Breite × Höhe / 750. 768 px ≈ 790 Tokens statt ≈ 1400 bei 1024 px.
        // Kalibrierung: am Referenzsatz prüfen, ob kleine Teile (1×1) noch sicher erkannt werden.
        guard let jpeg = image.uprightResized(maxSide: 768).jpegData(compressionQuality: 0.85) else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue(appKey, forHTTPHeaderField: "x-app-key")
        if !sets.isEmpty { request.setValue(sets.joined(separator: ","), forHTTPHeaderField: "x-sets") }
        let (data, response) = try await URLSession.shared.upload(for: request, from: jpeg)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        struct Answer: Decodable { let parts: [DetectedPart]; let ms: Int }
        let answer = try JSONDecoder().decode(Answer.self, from: data)
        #if DEBUG
        let summary = answer.parts.map { "\($0.partNo) \($0.colorName) \(Int($0.confidence * 100))%" }
        print("SCAN Backend \(answer.ms) ms:", summary)
        // Nur Entwicklung: gesendetes Bild aufheben, um Fehlerkennungen am Mac nachzustellen.
        let dir = URL.documentsDirectory.appending(path: "scans")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(Int(Date().timeIntervalSince1970))_\(summary.joined(separator: "+").replacingOccurrences(of: " ", with: "_")).jpg"
        try? jpeg.write(to: dir.appending(path: name))
        #endif
        return answer.parts.filter { $0.confidence >= minScore }
    }
}

extension Backend {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Teileliste und Bauabschnitte eines Sets („10132“ oder „10132-1“).
    static func fetchSet(_ number: String) async throws -> LegoSet {
        var components = URLComponents(url: url.deletingLastPathComponent().appending(path: "sets"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "no", value: number.trimmingCharacters(in: .whitespaces))]
        var request = URLRequest(url: components.url!, timeoutInterval: 90) // große Sets (7.500 Teile) beim ersten Abruf ≈ 30 s
        request.setValue(appKey, forHTTPHeaderField: "x-app-key")
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 {
            struct Message: Decodable { let error: String }
            throw Failure(errorDescription: (try? JSONDecoder().decode(Message.self, from: data))?.error ?? "Set nicht gefunden.")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(LegoSet.self, from: data)
    }
}

enum BrickLink {
    /// Alle BrickLink-Farben (Name → ID), für die Farbauswahl in der Kiste.
    static let colors: [(name: String, id: Int)] = {
        guard let url = Bundle.main.url(forResource: "bricklink_colors", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: Int].self, from: data) else { return [] }
        return map.map { ($0.key, $0.value) }.sorted { $0.name < $1.name }
    }()

    /// Katalogseite des Teils, mit Farbe vorgewählt, wenn bekannt.
    static func url(part: String, colorID: Int?) -> URL {
        let color = colorID.map { "&idColor=\($0)" } ?? ""
        return URL(string: "https://www.bricklink.com/v2/catalog/catalogitem.page?P=\(part)\(color)")!
    }

    /// Katalogseite eines Sets.
    static func url(set: String) -> URL {
        URL(string: "https://www.bricklink.com/v2/catalog/catalogitem.page?S=\(set)")!
    }

    /// Offizielles BrickLink-Teilebild in der Farbe.
    static func imageURL(part: String, colorID: Int?) -> URL? {
        guard let colorID else { return nil }
        return URL(string: "https://img.bricklink.com/ItemImage/PN/\(colorID)/\(part).png")
    }
}

extension UIImage {
    /// Aufrecht gedreht, max. `maxSide` Pixel, Skalierung 1 (Punkte = Pixel).
    func uprightResized(maxSide: CGFloat) -> UIImage {
        let scale = min(1, maxSide / max(size.width, size.height))
        let newSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

import UIKit

struct BrickognizeResponse: Decodable {
    let listing_id: String?
    let items: [Item]
    let bounding_box: Box?

    struct Box: Decodable {
        let left, upper, right, lower, image_width, image_height: Double

        /// Rahmen um das Teil, normiert auf 0…1.
        var normalized: CGRect {
            CGRect(x: left / image_width, y: upper / image_height,
                   width: (right - left) / image_width, height: (lower - upper) / image_height)
        }
    }

    struct Item: Decodable, Identifiable {
        let id: String
        let name: String
        let img_url: URL?
        let category: String?
        let score: Double
    }
}

enum BrickLink {
    /// Katalogseite des Teils, mit Farbe vorgewählt, wenn die BrickLink-Farb-ID bekannt ist.
    static func url(part: String, colorID: Int?) -> URL {
        let color = colorID.map { "&idColor=\($0)" } ?? ""
        return URL(string: "https://www.bricklink.com/v2/catalog/catalogitem.page?P=\(part)\(color)")!
    }
}

/// Ein erkanntes Teil: bester Treffer, geschätzte Farbe und Rahmen im Bild (normiert, Ursprung oben links).
struct ScanResult {
    let item: BrickognizeResponse.Item
    /// Alle plausiblen Teilenummern (≥ 50 %). Aus schrägem Winkel landet ein Teil oft auf einer ähnlichen
    /// Variante (6232 ↔ 4730); steht das zuletzt gezählte Teil hier mit drin, ist es dasselbe.
    let candidates: [String]
    let color: LegoColor?
    let box: CGRect?
    let listingID: String?        // für Feedback an Brickognize
    let measured: SIMD3<Double>?  // gemessene Farbe, damit Korrekturen gelernt werden können
}

enum Brickognize {
    /// Rückmeldung an Brickognize, ob die Erkennung stimmte. Damit lernt deren Modell dazu.
    /// Gesendet werden nur IDs (Suchergebnis + Teilenummer), kein Bild.
    static func sendFeedback(listingID: String, partID: String, correct: Bool) {
        var request = URLRequest(url: URL(string: "https://api.brickognize.com/feedback/")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "listing_id": listingID, "item_id": partID, "item_type": "part",
            "is_prediction_correct": correct, "source": "external-app", "item_rank": 0,
        ])
        Task.detached {
            let status = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode
            #if DEBUG
            print("FEEDBACK", partID, correct ? "richtig" : "falsch", "→ HTTP", status ?? -1)
            #endif
        }
    }

    /// Brickognize liefert immer das ähnlichste LEGO-Teil, auch für eine Tasse. Deshalb zwei Schwellen:
    /// unter `minScore` = nichts erkannt, ab `sureScore` = sicher, dazwischen fragt die App nach.
    // Kalibrierung (gemessen): echte Teile 0,79–0,90, gelbe Tasse 0,52 ("Duplo Ball Tube").
    // Fallen echte Teile bei schlechtem Licht durch, minScore senken.
    static let minScore = 0.65
    static let sureScore = 0.8 // mehrere kleine Teile: "Wedge Plate" (falsch) kam mit 75 % durch, echte Teile live 83–91 %

    /// Foto → bester Treffer mit Farbe (nil, wenn kein Teil sicher erkannt wurde).
    /// `empty` = Brickognize hat gar nichts gefunden, z. B. leerer Tisch.
    @MainActor
    static func identify(_ image: UIImage) async throws -> (result: ScanResult?, empty: Bool) {
        // 512 px: gemessen gleich treffsicher wie 1024 px, aber halb so lange Übertragung.
        let upright = image.uprightResized(maxSide: 512)
        let started = Date.now
        let response = try await recognize(upright)
        #if DEBUG
        print(String(format: "SCAN Antwortzeit %.2f s", Date.now.timeIntervalSince(started)))
        print("SCAN Ergebnis:", response.items.prefix(3).map { "\($0.id) \($0.name) \(Int($0.score * 100))%" })
        #endif
        guard let top = response.items.first, top.score >= minScore else { return (nil, response.items.isEmpty) }
        let box = response.bounding_box?.normalized
        let colors = Rebrickable.colors(forPart: top.id)
        let measured = box.flatMap { box in upright.cgImage.flatMap { partColor(in: $0, box: box) } }
        // Erst gelernte Korrekturen des Nutzers, dann die allgemeine Farbwahl.
        let color = ColorMemory.choose(measured, among: colors) ?? measured.flatMap { colors.best(for: $0) } ?? colors.first
        #if DEBUG
        print("SCAN Farbe gemessen:", measured.map { "\(Int($0.x)),\(Int($0.y)),\(Int($0.z))" } ?? "–", "→", color?.name ?? "–")
        #endif
        let candidates = response.items.filter { $0.score >= 0.5 }.map(\.id)
        return (ScanResult(item: top, candidates: candidates, color: color, box: box,
                           listingID: response.listing_id, measured: measured), false)
    }

    /// `image` sollte schon `uprightResized` sein, damit der Rahmen zu den Pixeln passt.
    static func recognize(_ image: UIImage) async throws -> BrickognizeResponse {
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else { throw URLError(.cannotDecodeContentData) }

        let boundary = UUID().uuidString
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"query_image\"; filename=\"part.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpeg)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: "https://api.brickognize.com/predict/parts/")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(BrickognizeResponse.self, from: data)
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

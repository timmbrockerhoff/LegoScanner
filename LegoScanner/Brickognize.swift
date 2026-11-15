import UIKit

struct BrickognizeResponse: Decodable {
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
        let external_sites: [Site]

        struct Site: Decodable { let name: String; let url: URL }

        func bricklinkURL(colorID: Int? = nil) -> URL {
            if let colorID {
                return URL(string: "https://www.bricklink.com/v2/catalog/catalogitem.page?P=\(id)&idColor=\(colorID)")!
            }
            return external_sites.first { $0.name == "bricklink" }?.url
                ?? URL(string: "https://www.bricklink.com/v2/catalog/catalogitem.page?P=\(id)")!
        }
    }
}

enum Brickognize {
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

    /// Median-Farbe (sRGB, 0…255) aus der Mitte eines normierten Rahmens.
    // ponytail: nimmt nur die inneren 40 % des Rahmens gegen Hintergrund; bei sehr schrägen,
    // dünnen Teilen kann trotzdem Untergrund reinrutschen → dann Segmentierung (Vision) nehmen.
    func medianColor(in box: CGRect) -> SIMD3<Double>? {
        guard let cg = cgImage else { return nil }
        let inner = box.insetBy(dx: box.width * 0.3, dy: box.height * 0.3)
        let rect = CGRect(x: inner.minX * CGFloat(cg.width), y: inner.minY * CGFloat(cg.height),
                          width: inner.width * CGFloat(cg.width), height: inner.height * CGFloat(cg.height)).integral
        guard let crop = cg.cropping(to: rect) else { return nil }

        let n = 24
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return nil }

        func median(_ channel: Int) -> Double {
            let values = stride(from: channel, to: pixels.count, by: 4).map { pixels[$0] }.sorted()
            return Double(values[values.count / 2])
        }
        return SIMD3(median(0), median(1), median(2))
    }
}

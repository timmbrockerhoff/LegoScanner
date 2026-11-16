import CoreML
import os
import UIKit
import Vision

/// Erkennung auf dem iPhone, ohne Internet und ohne Kosten (Phase 2):
/// Vision findet die Teile im Scanfeld, das eigene Modell (LegoFingerprint, trainiert auf Renderings) erkennt die Form,
/// die Farbe kommt per Pixelvergleich aus den Farben, in denen die Form in den eigenen Sets vorkommt.
final class OnDeviceRecognizer: @unchecked Sendable {
    static let shared = OnDeviceRecognizer()

    // Kalibrierung (Ähnlichkeit 0–1 zum nächsten Fingerabdruck): ab `sureSimilarity` gezählt, darunter orange zum
    // Bestätigen, unter `minSimilarity` verworfen. Werte nach dem Beweistest an echten Scans nachstellen.
    static let sureSimilarity: Float = 0.6
    static let minSimilarity: Float = 0.35

    private let model: MLModel?
    private let classes: [String]
    private let prototypes: [[Float]]

    var isAvailable: Bool { model != nil && !classes.isEmpty }

    private init() {
        let config = MLModelConfiguration()
        config.computeUnits = .all // Neural Engine, wo möglich
        model = Bundle.main.url(forResource: "LegoFingerprint", withExtension: "mlmodelc").flatMap { try? MLModel(contentsOf: $0, configuration: config) }
        let table = Bundle.main.url(forResource: "lego_fingerprints", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: [Float]].self, from: $0) } ?? [:]
        classes = Array(table.keys)
        prototypes = classes.map { Self.normalized(table[$0]!) }
    }

    /// Scanfeld-Bild → erkannte Teile. Es kommen nur Formen in Frage, die in `candidates` (Teile der eigenen Sets) stehen.
    func recognize(_ image: UIImage, candidates: [LegoSet.Part]) -> [DetectedPart] {
        guard let model, let cg = image.uprightResized(maxSide: 1024).cgImage, !candidates.isEmpty else { return [] }
        let byShape = Dictionary(grouping: candidates) { Self.shape($0.part) }
        let allowed = classes.indices.filter { byShape[Self.shape(classes[$0])] != nil }
        guard !allowed.isEmpty, let pixels = RGBA(cg) else { return [] }

        // 1. Teile finden: Vordergrund-Objekte (auf weißem Papier zuverlässig)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        do { try handler.perform([request]) } catch {
            #if DEBUG
            debugLog("SCAN lokal: Vision-Fehler", error.localizedDescription)
            #endif
            return []
        }
        guard let observation = request.results?.first else {
            #if DEBUG
            debugLog("SCAN lokal: kein Vordergrund gefunden")
            #endif
            return []
        }
        #if DEBUG
        debugLog("SCAN lokal:", observation.allInstances.count, "Objekte,", allowed.count, "erlaubte Formen")
        #endif

        var found: [DetectedPart] = []
        for instance in observation.allInstances {
            guard let mask = try? observation.generateScaledMaskForImage(forInstances: [instance], from: handler),
                  let region = Self.region(mask: mask, pixels: pixels) else { continue }
            let box = region.box
            // Kalibrierung: winzige Flecken und Fast-alles-Masken (Papierkante, Hand) überspringen
            guard box.width * box.height > 0.002, box.width * box.height < 0.8 else { continue }

            // 2. Form erkennen: quadratischer Ausschnitt ums Teil → Fingerabdruck → nächster erlaubter Fingerabdruck
            let side = max(box.width * CGFloat(cg.width), box.height * CGFloat(cg.height)) * 1.3
            let crop = CGRect(x: box.midX * CGFloat(cg.width) - side / 2, y: box.midY * CGFloat(cg.height) - side / 2, width: side, height: side)
                .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            guard let cropped = cg.cropping(to: crop.integral), let fingerprint = fingerprint(cropped, model: model) else { continue }
            let scored = allowed.map { ($0, zip(fingerprint, prototypes[$0]).reduce(0) { $0 + $1.0 * $1.1 }) }.sorted { $0.1 > $1.1 }
            #if DEBUG
            debugLog("SCAN lokal: Objekt", box, "beste:", scored.prefix(3).map { "\(classes[$0.0]) \(String(format: "%.2f", $0.1))" })
            #endif
            guard let (best, similarity) = scored.first, similarity >= Self.minSimilarity,
                  let options = byShape[Self.shape(classes[best])] else { continue }

            // 3. Farbe: von den Farben dieser Form in den Sets die, die der Pixelfarbe am nächsten ist
            let part = options.min { Self.distance(region.color, $0.rgb) < Self.distance(region.color, $1.rgb) } ?? options[0]
            found.append(DetectedPart(partNo: part.part, name: part.name, colorName: part.color, colorId: part.colorId,
                                      confidence: similarity >= Self.sureSimilarity ? 0.95 : 0.7,
                                      box: .init(x: box.minX, y: box.minY, w: box.width, h: box.height)))
            #if DEBUG
            debugLog("SCAN lokal:", part.part, part.color, String(format: "%.2f", similarity), "nächste:", scored.dropFirst().prefix(2).map { "\(classes[$0.0]) \(String(format: "%.2f", $0.1))" })
            #endif
        }
        return found
    }

    // MARK: Hilfen

    private func fingerprint(_ image: CGImage, model: MLModel) -> [Float]? {
        guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
              let input = try? MLFeatureValue(cgImage: image, constraint: constraint, options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue]),
              let output = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input])),
              let array = output.featureValue(for: "fingerprint")?.multiArrayValue else { return nil }
        return Self.normalized((0..<array.count).map { array[$0].floatValue })
    }

    private static func normalized(_ v: [Float]) -> [Float] {
        let length = max(sqrt(v.reduce(0) { $0 + $1 * $1 }), 1e-6)
        return v.map { $0 / length }
    }

    /// BrickLink- und LDraw-Nummern derselben Form vergleichbar machen: "3062b" → "3062", "3069bpb0005" → "3069".
    static func shape(_ no: String) -> String {
        no.lowercased()
            .replacingOccurrences(of: #"(pb\d+[a-z]?|px\d+|pr\d+|p\d+[a-z]?|c\d\d)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[a-d]$"#, with: "", options: .regularExpression)
    }

    /// Rahmen (0–1, Ursprung oben links) und mittlere Farbe der Maske.
    private static func region(mask: CVPixelBuffer, pixels: RGBA) -> (box: CGRect, color: SIMD3<Float>)? {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask)
        let row = CVPixelBufferGetBytesPerRow(mask)
        var minX = width, minY = height, maxX = 0, maxY = 0
        var sum = SIMD3<Float>(0, 0, 0), count: Float = 0
        for y in stride(from: 0, to: height, by: 2) {
            let line = (base + y * row).assumingMemoryBound(to: Float32.self)
            for x in stride(from: 0, to: width, by: 2) where line[x] > 0.5 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                sum += pixels.color(x: x * pixels.width / width, y: y * pixels.height / height)
                count += 1
            }
        }
        guard count > 0 else { return nil }
        let box = CGRect(x: CGFloat(minX) / CGFloat(width), y: CGFloat(minY) / CGFloat(height),
                         width: CGFloat(maxX - minX + 2) / CGFloat(width), height: CGFloat(maxY - minY + 2) / CGFloat(height))
        return (box, sum / count)
    }

    private static func distance(_ color: SIMD3<Float>, _ hex: String?) -> Float {
        guard let hex, let value = UInt32(hex, radix: 16) else { return .greatestFiniteMagnitude }
        let target = SIMD3<Float>(Float(value >> 16 & 255), Float(value >> 8 & 255), Float(value & 255)) / 255
        let d = color - target
        return (d * d).sum()
    }
}

/// Bild als RGBA-Bytes, um Farben unter der Maske zu lesen.
private struct RGBA {
    let width: Int, height: Int
    private let bytes: [UInt8]

    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        width = w; height = h; bytes = data
    }

    func color(x: Int, y: Int) -> SIMD3<Float> {
        let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return SIMD3(Float(bytes[i]), Float(bytes[i + 1]), Float(bytes[i + 2])) / 255
    }
}

#if DEBUG
private let logger = Logger(subsystem: "de.brockerhoff.LegoScanner", category: "scan")
/// Entwickler-Build: Diagnose ins Systemprotokoll (auch im Simulator mit `log show` lesbar).
private func debugLog(_ items: Any...) {
    let text = items.map { "\($0)" }.joined(separator: " ")
    logger.debug("\(text, privacy: .public)")
}
#endif

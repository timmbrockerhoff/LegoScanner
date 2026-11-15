import Accelerate
import AVFoundation
import Observation
import UIKit
import Vision

/// Ein Teil im Bild, das erkannt wurde und verfolgt wird.
struct SeenPart: Identifiable {
    enum State { case counted, unsure }
    let id = UUID()
    var box: CGRect // normiert aufs Kamerabild, Ursprung oben links
    let scan: ScanResult
    var state: State
    var label: String { [scan.item.name, scan.color?.name].compactMap { $0 }.joined(separator: " · ") }
}

/// Live-Scanner: Die Kamera läuft dauerhaft. Liegt das Bild ruhig, zerlegt der `PartFinder` es in einzelne
/// Teile; nur Teile, die noch nicht verfolgt werden, gehen an Brickognize (alle gleichzeitig). Erkannte Teile
/// werden per Vision-Tracking festgehalten, damit Wackeln nichts neu auslöst oder doppelt zählt.
@MainActor @Observable
final class Scanner: NSObject {
    enum Camera { case starting, running, denied, unavailable }
    enum Phase: Equatable { case searching, holdStill, recognizing(Int), done(String), notFound, failed }

    var camera: Camera = .starting
    var phase: Phase = .searching
    private(set) var parts: [SeenPart] = []
    /// Größe der Kamerabilder (hochkant), um Rahmen auf die Vorschau umzurechnen.
    private(set) var imageSize = CGSize(width: 1080, height: 1920)

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored var basket: Basket?
    @ObservationIgnored private let videoQueue = DispatchQueue(label: "scanner.video")
    @ObservationIgnored nonisolated(unsafe) private let analyzer = FrameAnalyzer() // nur auf videoQueue
    /// Gezählte Teile, die das Tracking gerade verloren hat (Wackeln, kurz verdeckt). Tauchen sie innerhalb
    /// von `reacquireSeconds` wieder auf, werden sie nicht noch einmal gezählt.
    @ObservationIgnored private var recentlyLost: [(candidates: [String], at: Date)] = []
    static let reacquireSeconds: TimeInterval = 5

    /// Scanfeld: 80 % der Bildbreite, quadratisch, etwas über der Mitte. Nur hier wird gesucht und erkannt.
    // Kalibrierung: Größe/Lage hier ändern, Anzeige passt sich automatisch an.
    nonisolated static func scanArea(imageSize: CGSize) -> CGRect {
        let height = 0.8 * imageSize.width / imageSize.height
        return CGRect(x: 0.1, y: 0.45 - height / 2, width: 0.8, height: height)
    }

    var scanArea: CGRect { Self.scanArea(imageSize: imageSize) }

    var hasUnsure: Bool { parts.contains { $0.state == .unsure } }

    func start() async {
        guard camera == .starting else { return }
        // Virtuelle Mehrfachkamera zuerst: schaltet bei kleinen, nahen Teilen selbst auf Makro um.
        guard let device = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            camera = .unavailable
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            camera = .denied
            return
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)

        session.beginConfiguration()
        // 4K, damit kleine Teile im Ausschnitt genug Pixel für Brickognize haben (bei 1080p nur ~60 px).
        session.sessionPreset = session.canSetSessionPreset(.hd4K3840x2160) ? .hd4K3840x2160 : .hd1920x1080
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        output.connection(with: .video)?.videoRotationAngle = 90 // Bilder hochkant
        session.commitConfiguration()

        setRunning(true)
        camera = .running
    }

    /// Kamera an/aus, z. B. während der Warenkorb offen ist.
    func setRunning(_ running: Bool) {
        guard camera != .denied, camera != .unavailable else { return }
        let session = session
        videoQueue.async { running ? session.startRunning() : session.stopRunning() }
    }

    /// Teile aus einem Foto der Mediathek scannen (auch mehrere).
    func scan(photo: UIImage) {
        guard let image = photo.uprightResized(maxSide: 1024).cgImage else { return }
        phase = .recognizing(0)
        Task {
            let regions = await Task.detached { PartFinder.find(in: image) }.value
            await recognize(regions, area: nil, thumb: nil)
        }
    }

    /// Orange (unsicher) erkanntes Teil per Antippen doch zählen.
    func confirm(_ id: SeenPart.ID) {
        guard let index = parts.firstIndex(where: { $0.id == id }), parts[index].state == .unsure else { return }
        let scan = parts[index].scan
        if let listing = scan.listingID {
            Brickognize.sendFeedback(listingID: listing, partID: scan.item.id, correct: true)
        }
        basket?.add(scan)
        parts[index].state = .counted
        phase = .done(parts[index].label)
    }

    private func handle(moved: [(UUID, CGRect)], lost: [UUID], decision: FrameAnalyzer.Decision,
                        regions: [FoundRegion]?, area: CGRect, thumb: [UInt8], size: CGSize) {
        imageSize = size
        for (id, box) in moved {
            if let index = parts.firstIndex(where: { $0.id == id }) { parts[index].box = box }
        }
        for id in lost {
            guard let index = parts.firstIndex(where: { $0.id == id }) else { continue }
            if parts[index].state == .counted { recentlyLost.append((parts[index].scan.candidates, .now)) }
            parts.remove(at: index)
        }

        if case .recognizing = phase { return }
        switch decision {
        case .moving: if parts.isEmpty { phase = .searching }
        case .settling: if parts.isEmpty { phase = .holdStill }
        case .idle: break
        case .scan:
            guard let regions else { break }
            Task { await recognize(regions, area: area, thumb: thumb) }
        }
    }

    /// Alle neuen Bereiche gleichzeitig an Brickognize, Ergebnisse zählen bzw. zum Bestätigen anzeigen.
    /// `area` = Scanfeld (nur Kamera), nil bei Fotos aus der Mediathek.
    private func recognize(_ regions: [FoundRegion], area: CGRect?, thumb: [UInt8]?) async {
        defer {
            let analyzer = analyzer
            videoQueue.async { analyzer.busy = false }
        }
        guard !regions.isEmpty else {
            // Kamera: alles im Bild wird schon verfolgt → nichts zu tun. Sonst: leerer Tisch.
            if parts.isEmpty {
                phase = .notFound
                markEmpty(thumb)
            }
            return
        }
        phase = .recognizing(regions.count)

        let outcomes = await withTaskGroup(of: (FoundRegion, Result<ScanResult?, Error>).self) { group in
            for region in regions {
                group.addTask {
                    do { return (region, .success(try await Brickognize.identify(region.image).result)) }
                    catch { return (region, .failure(error)) }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        recentlyLost.removeAll { Date.now.timeIntervalSince($0.at) > Self.reacquireSeconds }
        var newlyCounted: [String] = [], recognized = 0, failed = 0
        for (region, outcome) in outcomes {
            guard case .success(let result) = outcome else { failed += 1; continue }
            guard let scan = result else { // kein LEGO (Holzmaserung, Tasse …): eine Weile nicht wieder fragen
                if let area {
                    let analyzer = analyzer, box = region.box.mapped(into: area)
                    videoQueue.async { analyzer.ignore(box) }
                }
                continue
            }
            recognized += 1
            let state: SeenPart.State
            if let index = recentlyLost.firstIndex(where: { !Set($0.candidates).isDisjoint(with: scan.candidates) }) {
                recentlyLost.remove(at: index) // dasselbe Teil, nur kurz aus dem Tracking gefallen
                state = .counted
            } else if scan.item.score < Brickognize.sureScore {
                state = .unsure
            } else {
                basket?.add(scan)
                newlyCounted.append([scan.item.name, scan.color?.name].compactMap { $0 }.joined(separator: " · "))
                state = .counted
            }
            guard let area else { continue } // Mediathek: keine Rahmen im Kamerabild
            // Brickognize-Rahmen (relativ zum Ausschnitt) ist genauer als der grobe Suchrahmen
            let box = (scan.box?.mapped(into: region.cropRect) ?? region.box).mapped(into: area)
            let part = SeenPart(box: box, scan: scan, state: state)
            parts.append(part)
            let analyzer = analyzer
            videoQueue.async { analyzer.startTracking(part.id, box: box) }
        }

        if !newlyCounted.isEmpty {
            phase = .done(newlyCounted.count == 1 ? newlyCounted[0] : "\(newlyCounted.count) Teile gezählt")
        } else if recognized > 0 {
            phase = .done(parts.count == 1 ? parts[0].label : "\(parts.count) Teile im Bild")
        } else if failed > 0 {
            phase = .failed
        } else {
            phase = .notFound
            if parts.isEmpty { markEmpty(thumb) }
        }
    }

    private func markEmpty(_ thumb: [UInt8]?) {
        guard let thumb else { return }
        let analyzer = analyzer
        videoQueue.async { analyzer.empty = thumb }
    }
}

extension Scanner: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard analyzer.nextFrame(), let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        let area = Scanner.scanArea(imageSize: size)
        let (moved, lost) = analyzer.trackAll(pixels, area: area)
        let thumb = FrameAnalyzer.thumbnail(pixels, area: area)
        let decision = analyzer.evaluate(thumb)

        var regions: [FoundRegion]?
        if decision == .scan, let roi = FrameAnalyzer.cgImage(from: pixels, area: area) {
            // Nur Bereiche, die noch kein verfolgtes Teil sind: Wackeln kostet so keine Netzwerk-Anfragen.
            let tracked = analyzer.trackedBoxes, ignored = analyzer.ignoredBoxes
            regions = PartFinder.find(in: roi).filter { region in
                let full = region.box.mapped(into: area)
                return !tracked.contains { PartFinder.overlap($0, full) > 0.3 }
                    && !ignored.contains { PartFinder.overlap($0, full) > 0.5 }
            }
            #if DEBUG
            print("SCAN Bereiche neu: \(regions?.count ?? 0), verfolgt: \(tracked.count)")
            #endif
        }
        Task { @MainActor in
            self.handle(moved: moved, lost: lost, decision: decision, regions: regions, area: area, thumb: thumb, size: size)
        }
    }
}

/// Bewegungserkennung (32×32-Helligkeitsraster) und Tracking der erkannten Teile. Nur auf der Video-Queue benutzen.
final class FrameAnalyzer {
    enum Decision { case moving, settling, idle, scan }

    // Kalibrierung (am echten iPhone gemessen):
    static let frameStride = 2       // jedes 2. Kamerabild analysieren (≈ 15 pro Sekunde)
    static let cellDelta = 20        // ab dieser Helligkeitsänderung (0–255) zählt eine Rasterzelle als verändert
    static let motionShare = 0.02    // > 2 % veränderte Zellen zur letzten Analyse = Bewegung
    static let newSceneShare = 0.05  // > 5 % Unterschied zum zuletzt gescannten Bild = etwas Neues
                                     // (gemessen: ruhiges Bild schwankt bis 0,023, Teilewechsel ≈ 0,3)
    static let stillNeeded = 5       // so viele ruhige Analysen in Folge (≈ 0,33 s), dann wird gescannt
    static let trackConfidence: Float = 0.3 // darunter gilt ein Frame als "Teil nicht sicher gefunden"
    static let lostAfter = 4         // so viele unsichere Frames in Folge (≈ 0,27 s) = Teil weg
    static let maxTracked = 8

    var busy = false
    var empty: [UInt8]?              // Bild, auf dem zuletzt kein Teil war (z. B. leerer Tisch)
    private var lastScan: [UInt8]?
    private var previous: [UInt8]?
    private var movedSinceScan = true // ohne Bewegung seit dem letzten Scan wird nie neu gescannt
    private var still = 0
    private var frame = 0

    /// Stellen ohne LEGO-Teil (laut Brickognize): werden eine Weile nicht wieder angefragt.
    static let ignoreSeconds: TimeInterval = 8
    private var ignored: [(box: CGRect, until: Date)] = []
    var ignoredBoxes: [CGRect] {
        ignored.removeAll { $0.until < .now }
        return ignored.map(\.box)
    }
    func ignore(_ box: CGRect) { ignored.append((box, .now + Self.ignoreSeconds)) }

    private let sequence = VNSequenceRequestHandler()
    private var tracks: [UUID: (observation: VNDetectedObjectObservation, weak: Int)] = [:]

    func nextFrame() -> Bool {
        frame += 1
        return frame % Self.frameStride == 0
    }

    // MARK: Tracking

    var trackedBoxes: [CGRect] { tracks.values.map { Self.topLeft($0.observation.boundingBox) } }

    func startTracking(_ id: UUID, box: CGRect) {
        guard tracks.count < Self.maxTracked else { return }
        let vision = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        tracks[id] = (VNDetectedObjectObservation(boundingBox: vision), 0)
    }

    /// Alle verfolgten Teile ein Bild weiter: neue Rahmen und welche verloren gingen.
    func trackAll(_ pixels: CVPixelBuffer, area: CGRect) -> (moved: [(UUID, CGRect)], lost: [UUID]) {
        guard !tracks.isEmpty else { return ([], []) }
        let ids = Array(tracks.keys)
        let requests = ids.map { id in
            let request = VNTrackObjectRequest(detectedObjectObservation: tracks[id]!.observation)
            request.trackingLevel = .accurate
            return request
        }
        try? sequence.perform(requests, on: pixels)
        var moved: [(UUID, CGRect)] = [], lost: [UUID] = []
        for (id, request) in zip(ids, requests) {
            guard let result = request.results?.first as? VNDetectedObjectObservation else {
                tracks[id] = nil
                lost.append(id)
                continue
            }
            let box = Self.topLeft(result.boundingBox)
            let ok = result.confidence >= Self.trackConfidence && area.contains(CGPoint(x: box.midX, y: box.midY))
            let weak = ok ? 0 : tracks[id]!.weak + 1
            if weak >= Self.lostAfter {
                tracks[id] = nil
                lost.append(id)
            } else {
                tracks[id] = (result, weak)
                moved.append((id, box))
            }
        }
        return (moved, lost)
    }

    private static func topLeft(_ b: CGRect) -> CGRect { CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height) }

    // MARK: Bewegung

    func evaluate(_ thumb: [UInt8]) -> Decision {
        defer { previous = thumb }
        let motion = previous.map { Self.share(thumb, $0) } ?? 1
        let fromLast = lastScan.map { Self.share(thumb, $0) } ?? 1
        let fromEmpty = empty.map { Self.share(thumb, $0) } ?? 1
        still = motion <= Self.motionShare ? still + 1 : 0
        let decision: Decision
        if still == 0 {
            movedSinceScan = true
            decision = .moving
        } else if !movedSinceScan || fromLast <= Self.newSceneShare || fromEmpty <= Self.newSceneShare || busy {
            decision = .idle
        } else {
            decision = still >= Self.stillNeeded ? .scan : .settling
        }
        if decision == .scan {
            busy = true
            lastScan = thumb
            movedSinceScan = false
        }
        return decision
    }

    /// Anteil der Rasterzellen, die sich deutlich unterscheiden.
    static func share(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 1 }
        return Double(zip(a, b).filter { abs(Int($0) - Int($1)) > cellDelta }.count) / Double(a.count)
    }

    /// Helligkeit (Y-Ebene) im Scanfeld, auf 32×32 verkleinert, jede Zelle = Mittel ihres Bildbereichs.
    static func thumbnail(_ pixels: CVPixelBuffer, area: CGRect, grid: Int = 32) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return [] }
        let width = CGFloat(CVPixelBufferGetWidthOfPlane(pixels, 0)), height = CGFloat(CVPixelBufferGetHeightOfPlane(pixels, 0))
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let crop = CGRect(x: area.minX * width, y: area.minY * height,
                          width: area.width * width, height: area.height * height).integral
        var source = vImage_Buffer(data: base + Int(crop.minY) * rowBytes + Int(crop.minX),
                                   height: vImagePixelCount(crop.height),
                                   width: vImagePixelCount(crop.width),
                                   rowBytes: rowBytes)
        var cells = [UInt8](repeating: 0, count: grid * grid)
        let error = cells.withUnsafeMutableBytes { bytes in
            var target = vImage_Buffer(data: bytes.baseAddress, height: vImagePixelCount(grid),
                                       width: vImagePixelCount(grid), rowBytes: grid)
            return vImageScale_Planar8(&source, &target, nil, vImage_Flags(kvImageNoFlags))
        }
        return error == kvImageNoError ? cells : []
    }

    private static let ciContext = CIContext()

    /// Kamerabild, auf das Scanfeld zugeschnitten.
    static func cgImage(from pixels: CVPixelBuffer, area: CGRect) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixels)
        guard let full = ciContext.createCGImage(image, from: image.extent) else { return nil }
        let crop = CGRect(x: area.minX * CGFloat(full.width), y: area.minY * CGFloat(full.height),
                          width: area.width * CGFloat(full.width), height: area.height * CGFloat(full.height)).integral
        return full.cropping(to: crop)
    }
}

extension CGRect {
    /// Rahmen, der relativ (0…1) zu `outer` angegeben ist, aufs Gesamtbild umrechnen.
    func mapped(into outer: CGRect) -> CGRect {
        CGRect(x: outer.minX + minX * outer.width, y: outer.minY + minY * outer.height,
               width: width * outer.width, height: height * outer.height)
    }
}

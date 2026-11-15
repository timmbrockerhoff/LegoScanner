import Accelerate
import AVFoundation
import Observation
import UIKit
import Vision

/// Live-Scanner: Die Kamera läuft dauerhaft. Liegt ein neues Teil ruhig im Bild, wird ein Bild an
/// Brickognize geschickt und das Ergebnis in den Warenkorb gelegt. Dann wartet er auf das nächste Teil.
@MainActor @Observable
final class Scanner: NSObject {
    enum Camera { case starting, running, denied, unavailable }
    enum Phase: Equatable { case searching, holdStill, recognizing, found(String), confirm(String, Reason), notFound, failed }
    /// Warum ein Treffer erst nach Tipp auf "+" gezählt wird.
    enum Reason { case duplicate, unsure }

    var camera: Camera = .starting
    var phase: Phase = .searching
    private(set) var liveBox: CGRect?
    private(set) var resultBox: CGRect?
    /// Größe der Kamerabilder (hochkant), um Rahmen auf die Vorschau umzurechnen.
    private(set) var imageSize = CGSize(width: 1080, height: 1920)

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored var basket: Basket?
    @ObservationIgnored private let videoQueue = DispatchQueue(label: "scanner.video")
    @ObservationIgnored nonisolated(unsafe) private let analyzer = FrameAnalyzer() // nur auf videoQueue
    /// Zuletzt gezähltes Teil. Wird es direkt wieder erkannt (z. B. weil das iPhone bewegt wurde),
    /// zählt es erst nach Bestätigung. Ein leerer Tisch dazwischen setzt das zurück.
    /// `pending` = Treffer, der auf "+" wartet (Duplikat oder unsicher).
    @ObservationIgnored private var lastAddedPart: String? // nur Teilenummer: die Farbschätzung kann beim Verschieben schwanken
    @ObservationIgnored private var pending: ScanResult?
    /// Wann das Tracking zuletzt ein gezähltes Teil verloren hat (z. B. bei starkem Wackeln).
    @ObservationIgnored private var lostAt: Date?
    /// So lange gilt dasselbe Teil danach als "wiedergefunden" statt "schon gezählt".
    static let reacquireSeconds: TimeInterval = 5

    /// Scanfeld: Quadrat, 60 % der Bildbreite, etwas über der Mitte. Nur hier wird nach Bewegung
    /// gesucht, erkannt und die Farbe gemessen, damit Tasse, Hand & Co. daneben nicht stören.
    // Kalibrierung: Größe/Lage hier ändern, Anzeige passt sich automatisch an.
    nonisolated static func scanArea(imageSize: CGSize) -> CGRect {
        let height = 0.6 * imageSize.width / imageSize.height
        return CGRect(x: 0.2, y: 0.45 - height / 2, width: 0.6, height: height)
    }

    var scanArea: CGRect { Self.scanArea(imageSize: imageSize) }

    /// Rahmen, der gerade auf dem Bildschirm zu sehen sein soll.
    var displayBox: CGRect? {
        switch phase {
        case .found, .confirm: resultBox
        case .holdStill, .recognizing: liveBox
        default: nil
        }
    }

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
        session.sessionPreset = .hd1920x1080
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

    /// Teil aus einem Foto der Mediathek scannen.
    func scan(photo: UIImage) {
        Task { await recognize(photo, thumb: nil) }
    }

    /// Wartenden Treffer (Duplikat oder unsicher) doch zählen.
    func confirmPending() {
        guard let pending, case .confirm(let text, _) = phase else { return }
        add(pending)
        self.pending = nil
        phase = .found(text)
    }

    private func add(_ scan: ScanResult) {
        basket?.add(scan)
        lastAddedPart = scan.item.id
    }

    private func handle(_ decision: FrameAnalyzer.Decision, box: CGRect?, still: UIImage?, thumb: [UInt8], size: CGSize) {
        imageSize = size
        liveBox = box
        guard phase != .recognizing else { return }
        switch decision {
        case .moving:
            phase = .searching
            pending = nil
        case .settling: phase = .holdStill
        case .idle: break // Ergebnis stehen lassen, bis sich wieder etwas bewegt
        case .scan: if let still { Task { await recognize(still, thumb: thumb) } }
        }
    }

    /// Verfolgtes Teil hat sich bewegt (iPhone gewackelt o. Ä.): Rahmen mitführen, sonst nichts tun.
    private func follow(_ box: CGRect, size: CGSize) {
        imageSize = size
        switch phase {
        case .found, .confirm: resultBox = box
        default: break
        }
    }

    /// Teil ist aus dem Bild (weggenommen, verdeckt): wieder auf das nächste Teil warten.
    private func trackingLost() {
        switch phase {
        case .found, .confirm:
            lostAt = .now
            phase = .searching
            resultBox = nil
            pending = nil
        default: break
        }
    }

    private func recognize(_ image: UIImage, thumb: [UInt8]?) async {
        phase = .recognizing
        resultBox = nil
        do {
            let (result, empty) = try await Brickognize.identify(image)
            if let scan = result {
                let text = [scan.item.name, scan.color?.name].compactMap { $0 }.joined(separator: " · ")
                // Rahmen nur fürs Kamerabild; Brickognize kennt nur den Ausschnitt → auf Gesamtbild umrechnen
                resultBox = thumb == nil ? nil : scan.box?.mapped(into: scanArea)
                // Nur sperren, solange das Teil noch im Warenkorb liegt (nach "Leeren" oder Löschen zählt es wieder).
                let stillInBasket = lastAddedPart.map { part in basket?.items.contains { $0.partID == part } == true } == true
                let duplicate = thumb != nil && stillInBasket && lastAddedPart.map(scan.candidates.contains) == true
                let reacquired = duplicate && lostAt.map { Date.now.timeIntervalSince($0) < Self.reacquireSeconds } == true
                lostAt = nil
                if reacquired {
                    phase = .found(text) // dasselbe Teil nach kurzem Tracking-Verlust: einfach weiter festhalten
                } else if scan.item.score < Brickognize.sureScore || duplicate {
                    pending = scan
                    phase = .confirm(text, scan.item.score < Brickognize.sureScore ? .unsure : .duplicate)
                } else {
                    add(scan)
                    phase = .found(text)
                }
            } else {
                if empty { lastAddedPart = nil } // nur ein wirklich leerer Rahmen hebt die Duplikatsperre auf
                phase = .notFound
                if let thumb { let analyzer = analyzer; videoQueue.async { analyzer.empty = thumb } }
            }
        } catch {
            phase = .failed
        }
        let analyzer = analyzer, track = resultBox
        videoQueue.async {
            if let track { analyzer.startTracking(track) } // Teil ab jetzt festhalten
            analyzer.busy = false
        }
    }
}

extension Scanner: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard analyzer.nextFrame(), let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        let area = Scanner.scanArea(imageSize: size)
        let thumb = FrameAnalyzer.thumbnail(pixels, area: area)
        switch analyzer.track(pixels, area: area, thumb: thumb) {
        case .holding(let box):
            Task { @MainActor in self.follow(box, size: size) }
            return // Teil ist noch da: kein neuer Scan, egal wie es wackelt
        case .lost:
            Task { @MainActor in self.trackingLost() }
        case .off:
            break
        }
        let decision = analyzer.evaluate(thumb)
        let box = decision == .idle ? nil : FrameAnalyzer.salientBox(pixels, area: area)
        let still = decision == .scan ? FrameAnalyzer.image(from: pixels, area: area) : nil
        Task { @MainActor in self.handle(decision, box: box, still: still, thumb: thumb, size: size) }
    }
}

/// Bewegungs- und "Neues Teil"-Erkennung auf einem 32×32-Helligkeitsraster (Bereichsmittel,
/// dadurch unempfindlich gegen Bildrauschen und leichtes Zittern der Hand). Nur auf der Video-Queue benutzen.
final class FrameAnalyzer {
    enum Decision { case moving, settling, idle, scan }

    // Kalibrierung (am echten iPhone nachjustieren):
    static let frameStride = 2       // jedes 2. Kamerabild analysieren (≈ 15 pro Sekunde)
    static let cellDelta = 20        // ab dieser Helligkeitsänderung (0–255) zählt eine Rasterzelle als verändert
    static let motionShare = 0.02    // > 2 % veränderte Zellen zur letzten Analyse = Bewegung
    static let newSceneShare = 0.05  // > 5 % Unterschied zum zuletzt gescannten Bild = neues Teil
                                     // (gemessen: ruhiges Bild schwankt bis 0,023, Teilewechsel ≈ 0,3)
    static let stillNeeded = 5       // so viele ruhige Analysen in Folge (≈ 0,33 s), dann wird gescannt

    // Tracking des erkannten Teils (Vision). Kalibrierung:
    static let trackConfidence: Float = 0.3 // darunter gilt ein Frame als "Teil nicht sicher gefunden"
    static let lostAfter = 4                // so viele unsichere Frames in Folge (≈ 0,27 s) = Teil weg

    enum Tracking { case off, holding(CGRect), lost }

    private let sequence = VNSequenceRequestHandler()
    private var tracked: VNDetectedObjectObservation?
    private var weakFrames = 0

    var busy = false
    private var lastScan: [UInt8]?
    var empty: [UInt8]?              // Bild, auf dem zuletzt kein Teil war (z. B. leerer Tisch)
    private var previous: [UInt8]?
    private var movedSinceScan = true // ohne Bewegung seit dem letzten Scan wird nie neu gescannt
    private var still = 0
    private var frame = 0

    /// Rahmen (normiert, Ursprung oben links) ab jetzt verfolgen.
    func startTracking(_ box: CGRect) {
        tracked = VNDetectedObjectObservation(boundingBox: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
        weakFrames = 0
    }

    /// Verfolgt das erkannte Teil. Solange es gehalten wird, gilt das aktuelle Bild als "schon gescannt".
    func track(_ pixels: CVPixelBuffer, area: CGRect, thumb: [UInt8]) -> Tracking {
        guard let tracked else { return .off }
        let request = VNTrackObjectRequest(detectedObjectObservation: tracked)
        request.trackingLevel = .accurate
        try? sequence.perform([request], on: pixels)
        guard let result = request.results?.first as? VNDetectedObjectObservation else {
            self.tracked = nil
            return .lost
        }
        let b = result.boundingBox
        let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
        let inFrame = area.contains(CGPoint(x: box.midX, y: box.midY))
        weakFrames = result.confidence >= Self.trackConfidence && inFrame ? 0 : weakFrames + 1
        #if DEBUG
        print(String(format: "TRACK conf %.2f imRahmen %d schwach %d", result.confidence, inFrame ? 1 : 0, weakFrames))
        #endif
        guard weakFrames < Self.lostAfter else {
            self.tracked = nil
            return .lost
        }
        self.tracked = result
        // Szene merken: geht das Tracking später verloren, das Teil liegt aber noch da, wird nicht neu gescannt.
        previous = thumb
        lastScan = thumb
        still = 0
        movedSinceScan = false
        return .holding(box)
    }

    func nextFrame() -> Bool {
        frame += 1
        return frame % Self.frameStride == 0
    }

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
        #if DEBUG
        print(String(format: "SCAN motion %.3f still %d vomLetzten %.3f vomLeeren %.3f busy %d → %@",
                     motion, still, fromLast, fromEmpty, busy ? 1 : 0, "\(decision)"))
        #endif
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

    /// Rahmen um das auffälligste Objekt im Scanfeld (normiert aufs Gesamtbild, Ursprung oben links), nur für die Anzeige.
    static func salientBox(_ pixels: CVPixelBuffer, area: CGRect) -> CGRect? {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        request.regionOfInterest = CGRect(x: area.minX, y: 1 - area.maxY, width: area.width, height: area.height) // Vision: Ursprung unten links
        try? VNImageRequestHandler(cvPixelBuffer: pixels).perform([request])
        guard let b = request.results?.first?.salientObjects?.max(by: { $0.confidence < $1.confidence })?.boundingBox
        else { return nil }
        return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height).mapped(into: area)
    }

    private static let ciContext = CIContext()

    /// Kamerabild, auf das Scanfeld zugeschnitten.
    static func image(from pixels: CVPixelBuffer, area: CGRect) -> UIImage? {
        let image = CIImage(cvPixelBuffer: pixels)
        guard let full = ciContext.createCGImage(image, from: image.extent) else { return nil }
        let crop = CGRect(x: area.minX * CGFloat(full.width), y: area.minY * CGFloat(full.height),
                          width: area.width * CGFloat(full.width), height: area.height * CGFloat(full.height)).integral
        return full.cropping(to: crop).map { UIImage(cgImage: $0) }
    }
}

extension CGRect {
    /// Rahmen, der relativ (0…1) zu `outer` angegeben ist, aufs Gesamtbild umrechnen.
    func mapped(into outer: CGRect) -> CGRect {
        CGRect(x: outer.minX + minX * outer.width, y: outer.minY + minY * outer.height,
               width: width * outer.width, height: height * outer.height)
    }
}

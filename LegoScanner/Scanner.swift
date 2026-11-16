import Accelerate
import AVFoundation
import CoreMotion
import Observation
import UIKit
import Vision

/// Ein Teil im Bild, das erkannt wurde und verfolgt wird.
struct SeenPart: Identifiable {
    enum State { case counted, unsure }
    let id = UUID()
    var box: CGRect // normiert aufs Kamerabild, Ursprung oben links
    let part: DetectedPart
    var state: State
    var label: String { part.label }
}

/// Live-Scanner: Die Kamera läuft dauerhaft. Liegt das Bild ruhig und hat sich etwas geändert, geht das
/// Scanfeld ans eigene Backend (Claude erkennt Teile, Farben und ihre Lage). Erkannte Teile werden per
/// Vision-Tracking festgehalten, damit Wackeln nichts neu auslöst oder doppelt zählt.
@MainActor @Observable
final class Scanner: NSObject {
    enum Camera { case starting, running, denied, unavailable }
    enum Phase: Equatable { case searching, holdStill, recognizing(Int), done(String), notFound, failed, tooDark, aimDown, paused }

    var camera: Camera = .starting
    var phase: Phase = .searching
    private(set) var parts: [SeenPart] = []
    /// Größe der Kamerabilder (hochkant), um Rahmen auf die Vorschau umzurechnen.
    private(set) var imageSize = CGSize(width: 1080, height: 1920)

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored var basket: Basket?
    @ObservationIgnored var sets: SetStore?
    @ObservationIgnored private let videoQueue = DispatchQueue(label: "scanner.video")
    @ObservationIgnored nonisolated(unsafe) private let analyzer = FrameAnalyzer() // nur auf videoQueue
    /// Gezählte Teile, die das Tracking gerade verloren hat (Wackeln, kurz verdeckt). Tauchen sie innerhalb
    /// von `reacquireSeconds` wieder auf und liegen noch in der Kiste, werden sie nicht noch einmal gezählt.
    @ObservationIgnored private var recentlyLost: [(partNo: String, at: Date)] = []
    static let reacquireSeconds: TimeInterval = 5

    // Kosten: Jeder Scan ist eine bezahlte Anfrage. Nur scannen, wenn die Kamera nach unten zeigt (Teile liegen
    // auf dem Tisch), und nach mehreren leeren Ergebnissen in Folge pausieren (App offen liegen gelassen).
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var emptyStreak = 0
    // Kalibrierung: Schwerkraft z = -1 heißt Display waagerecht nach oben; -0.7 erlaubt etwa 45° Neigung.
    static let maxGravityZ = -0.7
    static let emptyStreakPause = 3

    /// Kamera zeigt nach unten. Ohne Bewegungssensor (Simulator) immer ja.
    private var pointsDown: Bool { motion.deviceMotion.map { $0.gravity.z < Self.maxGravityZ } ?? true }

    /// Nach einer Pause wegen leerer Scans wieder automatisch scannen.
    func resume() {
        emptyStreak = 0
        phase = .searching
    }

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
        // 4K, damit kleine Teile im Scanfeld genug Pixel haben.
        session.sessionPreset = session.canSetSessionPreset(.hd4K3840x2160) ? .hd4K3840x2160 : .hd1920x1080
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        output.connection(with: .video)?.videoRotationAngle = 90 // Bilder hochkant
        session.commitConfiguration()

        motion.deviceMotionUpdateInterval = 0.2
        motion.startDeviceMotionUpdates()
        setRunning(true)
        camera = .running
    }

    /// Kamera an/aus, z. B. wenn der Scan-Tab verlassen wird.
    func setRunning(_ running: Bool) {
        guard camera != .denied, camera != .unavailable else { return }
        let session = session
        videoQueue.async {
            running ? session.startRunning() : session.stopRunning()
        }
    }

    /// Teile aus einem Foto der Mediathek scannen (auch mehrere).
    func scan(photo: UIImage) {
        Task { await recognize(photo, area: nil, thumb: nil) }
    }

    /// Orange (unsicher) erkanntes Teil per Antippen doch zählen.
    func confirm(_ id: SeenPart.ID) {
        guard let index = parts.firstIndex(where: { $0.id == id }), parts[index].state == .unsure else { return }
        parts[index].state = .counted
        phase = .done(count(parts[index].part))
    }

    /// Teil zählen: gehört es zu einem Set, das der Nutzer zusammensucht, dorthin, sonst in die Kiste.
    /// Rückgabe: Text für die Statuszeile.
    private func count(_ part: DetectedPart) -> String {
        if let assignment = sets?.assign(part) { return assignment.label }
        basket?.add(part)
        return part.label
    }

    private func handle(moved: [(UUID, CGRect)], lost: [UUID], decision: FrameAnalyzer.Decision,
                        image: UIImage?, area: CGRect, thumb: [UInt8], size: CGSize) {
        imageSize = size
        for (id, box) in moved {
            if let index = parts.firstIndex(where: { $0.id == id }) { parts[index].box = box }
        }
        for id in lost {
            guard let index = parts.firstIndex(where: { $0.id == id }) else { continue }
            if parts[index].state == .counted { recentlyLost.append((parts[index].part.partNo, .now)) }
            parts.remove(at: index)
        }

        if case .recognizing = phase { return }
        if phase == .paused { // bleibt pausiert, bis der Nutzer tippt
            if decision == .scan { let analyzer = analyzer; videoQueue.async { analyzer.busy = false } }
            return
        }
        switch decision {
        case .moving: if parts.isEmpty { phase = .searching }
        case .settling: if parts.isEmpty { phase = .holdStill }
        case .idle: break
        case .scan:
            guard let image else { break }
            // Bilder, aus denen nichts zu erkennen ist, gar nicht erst senden (jede Anfrage kostet).
            // Kalibrierung an iPhone-Scans: abgedeckt/schwarz ≈ 1–4, gut ≈ 65–110.
            let brightness = thumb.reduce(0) { $0 + Int($1) } / max(thumb.count, 1)
            if !pointsDown || brightness < 20 {
                phase = brightness < 20 ? .tooDark : .aimDown
                let analyzer = analyzer
                videoQueue.async { analyzer.busy = false }
                break
            }
            Task { await recognize(image, area: area, thumb: thumb) }
        }
    }

    /// Bild ans Backend, Ergebnisse zählen bzw. zum Bestätigen anzeigen.
    /// `area` = Scanfeld (nur Kamera), nil bei Fotos aus der Mediathek.
    private func recognize(_ image: UIImage, area: CGRect?, thumb: [UInt8]?) async {
        defer {
            let analyzer = analyzer
            videoQueue.async { analyzer.busy = false }
        }
        phase = .recognizing(parts.count + 1)
        var found: [DetectedPart] = []
        // Erst auf dem Gerät (kostenlos, offline), solange Sets gewählt sind. Claude nur, wenn das eigene Modell ein Teil
        // sieht, sich aber nicht sicher ist, oder wenn es (noch) kein eigenes Modell gibt.
        let candidates = sets?.sets.flatMap(\.lego.parts) ?? []
        let local = OnDeviceRecognizer.shared.isAvailable && !candidates.isEmpty
        if local {
            found = await Task.detached(priority: .userInitiated) { OnDeviceRecognizer.shared.recognize(image, candidates: candidates) }.value
        }
        if !local || found.contains(where: { $0.confidence < Backend.sureScore }) {
            do {
                found = try await Backend.identify(image, sets: sets?.setNumbers ?? [])
            } catch {
                #if DEBUG
                print("SCAN Backend-Fehler:", error.localizedDescription, Backend.url)
                #endif
                // Ohne Verbindung oder Guthaben: Ergebnisse vom Gerät behalten (unsichere bleiben orange zum Bestätigen)
                if found.isEmpty && !local {
                    phase = .failed
                    return
                }
            }
        }

        emptyStreak = found.isEmpty ? emptyStreak + 1 : 0
        recentlyLost.removeAll { Date.now.timeIntervalSince($0.at) > Self.reacquireSeconds }
        var newlyCounted: [String] = []
        for detected in found {
            let box = area.map { detected.rect.mapped(into: $0) }
            // Schon verfolgt (das Backend sieht immer das ganze Scanfeld): nichts tun
            if let box, parts.contains(where: { overlap($0.box, box) > 0.3 }) { continue }

            let state: SeenPart.State
            let lostIndex = recentlyLost.firstIndex { $0.partNo == detected.partNo }
            if let lostIndex { recentlyLost.remove(at: lostIndex) }
            if lostIndex != nil && basket?.contains(part: detected.partNo) == true {
                state = .counted // dasselbe Teil, nur kurz aus dem Tracking gefallen
            } else if detected.confidence < Backend.sureScore {
                state = .unsure
            } else {
                newlyCounted.append(count(detected))
                state = .counted
            }
            guard let box else { continue } // Mediathek: keine Rahmen im Kamerabild
            let part = SeenPart(box: box, part: detected, state: state)
            parts.append(part)
            let analyzer = analyzer
            videoQueue.async { analyzer.startTracking(part.id, box: box) }
        }

        if !newlyCounted.isEmpty {
            phase = .done(newlyCounted.count == 1 ? newlyCounted[0] : "\(newlyCounted.count) Teile gezählt")
        } else if !parts.isEmpty {
            phase = .done(parts.count == 1 ? parts[0].label : "\(parts.count) Teile im Bild")
        } else if !found.isEmpty {
            phase = .done(found.count == 1 ? found[0].label : "\(found.count) Teile erkannt")
        } else {
            phase = emptyStreak >= Self.emptyStreakPause && area != nil ? .paused : .notFound
            if let thumb {
                let analyzer = analyzer
                videoQueue.async { analyzer.empty = thumb }
            }
        }
    }

    /// Anteil der kleineren Fläche, der mit der anderen überlappt (0…1).
    private func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        return (inter.width * inter.height) / max(1e-9, min(a.width * a.height, b.width * b.height))
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
        let image = decision == .scan ? FrameAnalyzer.cgImage(from: pixels, area: area).map { UIImage(cgImage: $0) } : nil
        Task { @MainActor in
            self.handle(moved: moved, lost: lost, decision: decision, image: image, area: area, thumb: thumb, size: size)
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

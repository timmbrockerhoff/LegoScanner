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
    enum Phase: Equatable { case searching, holdStill, recognizing, found(String), duplicate(String), notFound, failed }

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
    @ObservationIgnored private var lastAdded: (part: String, color: Int?)?
    @ObservationIgnored private var pending: ScanResult?

    /// Rahmen, der gerade auf dem Bildschirm zu sehen sein soll.
    var displayBox: CGRect? {
        switch phase {
        case .found, .duplicate: resultBox
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

    /// Das gerade erkannte, schon gezählte Teil doch noch einmal zählen.
    func confirmDuplicate() {
        guard let pending, case .duplicate(let text) = phase else { return }
        add(pending)
        self.pending = nil
        phase = .found(text)
    }

    private func add(_ scan: ScanResult) {
        basket?.add(scan)
        lastAdded = (scan.item.id, scan.color?.id)
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

    private func recognize(_ image: UIImage, thumb: [UInt8]?) async {
        phase = .recognizing
        resultBox = nil
        do {
            if let scan = try await Brickognize.identify(image) {
                let text = [scan.item.name, scan.color?.name].compactMap { $0 }.joined(separator: " · ")
                resultBox = thumb == nil ? nil : scan.box // Rahmen nur, wenn er zum Kamerabild gehört
                if thumb != nil, lastAdded?.part == scan.item.id, lastAdded?.color == scan.color?.id {
                    pending = scan
                    phase = .duplicate(text)
                } else {
                    add(scan)
                    phase = .found(text)
                }
            } else {
                lastAdded = nil
                phase = .notFound
                if let thumb { let analyzer = analyzer; videoQueue.async { analyzer.empty = thumb } }
            }
        } catch {
            phase = .failed
        }
        let analyzer = analyzer
        videoQueue.async { analyzer.busy = false }
    }
}

extension Scanner: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard analyzer.nextFrame(), let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let thumb = FrameAnalyzer.thumbnail(pixels)
        let decision = analyzer.evaluate(thumb)
        let box = decision == .idle ? nil : FrameAnalyzer.salientBox(pixels)
        var still: UIImage?
        if decision == .scan {
            still = FrameAnalyzer.image(from: pixels)
        }
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        Task { @MainActor in self.handle(decision, box: box, still: still, thumb: thumb, size: size) }
    }
}

/// Bewegungs- und "Neues Teil"-Erkennung auf einem 32×32-Helligkeitsraster (Bereichsmittel,
/// dadurch unempfindlich gegen Bildrauschen und leichtes Zittern der Hand). Nur auf der Video-Queue benutzen.
final class FrameAnalyzer {
    enum Decision { case moving, settling, idle, scan }

    // Kalibrierung (am echten iPhone nachjustieren):
    static let frameStride = 3       // nur jedes 3. Kamerabild analysieren (≈ 10 pro Sekunde)
    static let cellDelta = 20        // ab dieser Helligkeitsänderung (0–255) zählt eine Rasterzelle als verändert
    static let motionShare = 0.02    // > 2 % veränderte Zellen zur letzten Analyse = Bewegung
    static let newSceneShare = 0.05  // > 5 % Unterschied zum zuletzt gescannten Bild = neues Teil
                                     // (gemessen: ruhiges Bild schwankt bis 0,023, Teilewechsel ≈ 0,3)
    static let stillNeeded = 6       // so viele ruhige Analysen in Folge (≈ 0,6 s), dann wird gescannt

    var busy = false
    private var lastScan: [UInt8]?
    var empty: [UInt8]?              // Bild, auf dem zuletzt kein Teil war (z. B. leerer Tisch)
    private var previous: [UInt8]?
    private var movedSinceScan = true // ohne Bewegung seit dem letzten Scan wird nie neu gescannt
    private var still = 0
    private var frame = 0

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

    /// Helligkeit (Y-Ebene), auf 32×32 verkleinert, jede Zelle = Mittel ihres Bildbereichs.
    static func thumbnail(_ pixels: CVPixelBuffer, grid: Int = 32) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return [] }
        var source = vImage_Buffer(data: base,
                                   height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(pixels, 0)),
                                   width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(pixels, 0)),
                                   rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0))
        var cells = [UInt8](repeating: 0, count: grid * grid)
        let error = cells.withUnsafeMutableBytes { bytes in
            var target = vImage_Buffer(data: bytes.baseAddress, height: vImagePixelCount(grid),
                                       width: vImagePixelCount(grid), rowBytes: grid)
            return vImageScale_Planar8(&source, &target, nil, vImage_Flags(kvImageNoFlags))
        }
        return error == kvImageNoError ? cells : []
    }

    /// Rahmen um das auffälligste Objekt (normiert, Ursprung oben links), nur für die Anzeige.
    static func salientBox(_ pixels: CVPixelBuffer) -> CGRect? {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pixels).perform([request])
        guard let b = request.results?.first?.salientObjects?.max(by: { $0.confidence < $1.confidence })?.boundingBox
        else { return nil }
        return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
    }

    private static let ciContext = CIContext()

    static func image(from pixels: CVPixelBuffer) -> UIImage? {
        let image = CIImage(cvPixelBuffer: pixels)
        return ciContext.createCGImage(image, from: image.extent).map { UIImage(cgImage: $0) }
    }
}

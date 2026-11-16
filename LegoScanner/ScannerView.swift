import AVFoundation
import PhotosUI
import SwiftUI

/// Scan-Tab: Teile vor die Kamera legen, sie werden erkannt, eingerahmt und deinen Sets zugeordnet
/// (was zu keinem Set gehört, kommt in die Kiste). Die Kamera läuft nur, solange dieser Tab offen ist.
struct ScannerView: View {
    let scanner: Scanner
    let basket: Basket
    let sets: SetStore
    @State private var photoItem: PhotosPickerItem?
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            switch scanner.camera {
            case .running, .starting:
                ZStack {
                    CameraPreview(session: scanner.session)
                    scanFrame
                    boxOverlay
                }
                .ignoresSafeArea(edges: .top)
            case .denied:
                ContentUnavailableView {
                    Label("Kein Kamerazugriff", systemImage: "camera.badge.ellipsis")
                } description: {
                    Text("Zum Scannen braucht die App die Kamera.")
                } actions: {
                    Button("Einstellungen öffnen") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                        .buttonStyle(.glassProminent)
                }
            case .unavailable:
                ContentUnavailableView("Keine Kamera", systemImage: "video.slash",
                                       description: Text("Scannen geht nur auf dem iPhone. Teile aus Fotos fügst du über die Mediathek hinzu."))
            }
        }
        .safeAreaInset(edge: .top) {
            if scanner.camera == .running || scanner.phase != .searching { status }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Mediathek", systemImage: "photo.on.rectangle")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Foto aus der Mediathek scannen")
                Spacer()
                Label(sets.sets.isEmpty ? "Kein Set ausgewählt – alles geht in die Kiste"
                      : sets.sets.count == 1 ? "Sucht für Set \(sets.sets[0].lego.no.replacingOccurrences(of: "-1", with: ""))" : "Sucht für \(sets.sets.count) Sets",
                      systemImage: "square.stack.3d.up")
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect()
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    scanner.scan(photo: image)
                }
                photoItem = nil
            }
        }
        .sensoryFeedback(trigger: basket.totalCount + sets.totalFound) { old, new in new > old ? .success : nil }
        .task { await scanner.start() } // erst beim ersten Öffnen des Tabs: dann fragt iOS nach der Kamera
        .onAppear { scanner.setRunning(true) }
        .onDisappear { scanner.setRunning(false) }
    }

    private var status: some View {
        HStack(spacing: 8) {
            switch scanner.phase {
            case .searching:
                Label("Leg Teile in den Rahmen", systemImage: "viewfinder")
            case .holdStill:
                Label("Stillhalten …", systemImage: "hand.raised")
            case .recognizing(let count):
                ProgressView()
                Text(count > 1 ? "Erkenne \(count) Teile …" : "Erkenne …")
            case .done(let text):
                if scanner.hasUnsure {
                    Label { Text("Orange antippen zum Zählen") } icon: {
                        Image(systemName: "hand.tap").foregroundStyle(.orange)
                    }
                } else {
                    Label { Text(text) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
            case .notFound:
                Label("Kein Teil erkannt", systemImage: "questionmark.circle")
            case .tooDark:
                Label("Zu dunkel – mehr Licht nötig", systemImage: "moon")
            case .aimDown:
                Label("Kamera von oben auf die Teile richten", systemImage: "arrow.down.circle")
            case .paused:
                Button("Pausiert – tippen zum Weiterscannen", systemImage: "pause.circle") { scanner.resume() }
            case .failed:
                Label("Keine Verbindung zur Erkennung", systemImage: "wifi.exclamationmark")
            }
        }
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect()
        .padding(.top, 8)
    }

    /// Sichtbares Scanfeld: außen abgedunkelt, innen ein heller Rahmen.
    private var scanFrame: some View {
        GeometryReader { geo in
            let rect = previewRect(scanner.scanArea, image: scanner.imageSize, view: geo.size)
            let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
            Path { path in
                path.addRect(CGRect(origin: .zero, size: geo.size))
                path.addPath(shape.path(in: rect))
            }
            .fill(.black.opacity(0.35), style: FillStyle(eoFill: true))
            shape
                .stroke(.white.opacity(0.9), lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
        .allowsHitTesting(false)
    }

    /// Ein Rahmen pro erkanntem Teil, mit Namen darüber. Grün = gezählt, orange = unsicher (antippen zählt).
    private var boxOverlay: some View {
        GeometryReader { geo in
            ForEach(scanner.parts) { part in
                let rect = previewRect(part.box, image: scanner.imageSize, view: geo.size)
                let color: Color = part.state == .counted ? .green : .orange
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(color, lineWidth: 3)
                        .shadow(color: .black.opacity(0.4), radius: 4)
                        .contentShape(.rect(cornerRadius: 14))
                    Label {
                        Text(part.label)
                    } icon: {
                        Image(systemName: part.state == .counted ? "checkmark.circle.fill" : "plus.circle.fill")
                            .foregroundStyle(color)
                    }
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassEffect()
                    .offset(y: -30)
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .onTapGesture { scanner.confirm(part.id) }
                .allowsHitTesting(part.state == .unsure)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(part.state == .unsure ? .isButton : [])
                .accessibilityHint(part.state == .unsure ? "Antippen, um das Teil zu zählen" : "")
            }
        }
        .animation(.smooth(duration: 0.25), value: scanner.parts.map(\.box))
    }
}

/// Normierten Bildrahmen (hochkant, Ursprung oben links) auf die Vorschau mit `.resizeAspectFill` umrechnen.
private func previewRect(_ box: CGRect, image: CGSize, view: CGSize) -> CGRect {
    let scale = max(view.width / image.width, view.height / image.height)
    let shown = CGSize(width: image.width * scale, height: image.height * scale)
    let origin = CGPoint(x: (view.width - shown.width) / 2, y: (view.height - shown.height) / 2)
    return CGRect(x: origin.x + box.minX * shown.width, y: origin.y + box.minY * shown.height,
                  width: box.width * shown.width, height: box.height * shown.height)
}

/// Live-Kamerabild.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.connection?.videoRotationAngle = 90 // hochkant, passend zu den Analysebildern
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

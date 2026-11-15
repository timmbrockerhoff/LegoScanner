import AVFoundation
import PhotosUI
import SwiftUI

/// Scanner-Bildschirm: Teil vor die Kamera legen, es wird erkannt, eingerahmt und landet im Warenkorb.
struct ContentView: View {
    @State private var basket = Basket()
    @State private var scanner = Scanner()
    @State private var showBasket = false
    @State private var photoItem: PhotosPickerItem?
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ZStack {
                switch scanner.camera {
                case .running, .starting:
                    ZStack {
                        CameraPreview(session: scanner.session)
                        scanFrame
                        boxOverlay
                    }
                    .ignoresSafeArea()
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
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Mediathek", systemImage: "photo.on.rectangle")
                    }
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button { showBasket = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "basket.fill")
                            Text("\(basket.totalCount)")
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityLabel("Warenkorb, \(basket.totalCount) Teile")
                }
            }
            .sheet(isPresented: $showBasket) { BasketView(basket: basket) }
            .onChange(of: showBasket) { _, open in scanner.setRunning(!open) }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        scanner.scan(photo: image)
                    }
                    photoItem = nil
                }
            }
            .sensoryFeedback(trigger: basket.totalCount) { old, new in new > old ? .success : nil }
            .animation(.default, value: basket.totalCount)
            .task {
                scanner.basket = basket
                await scanner.start()
            }
        }
    }

    private var status: some View {
        HStack(spacing: 8) {
            switch scanner.phase {
            case .searching:
                Label("Leg ein Teil in den Rahmen", systemImage: "viewfinder")
            case .holdStill:
                Label("Stillhalten …", systemImage: "hand.raised")
            case .recognizing:
                ProgressView()
                Text("Erkenne …")
            case .found(let text):
                Label { Text(text) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            case .duplicate(let text):
                Label { Text("Schon gezählt: \(text)") } icon: { Image(systemName: "checkmark.circle").foregroundStyle(.orange) }
                Button("Doch zählen", systemImage: "plus") { scanner.confirmDuplicate() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Noch einmal zählen")
            case .notFound:
                Label("Kein Teil erkannt", systemImage: "questionmark.circle")
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
        .animation(.default, value: scanner.phase)
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

    private var boxOverlay: some View {
        GeometryReader { geo in
            if let box = scanner.displayBox {
                let rect = previewRect(box, image: scanner.imageSize, view: geo.size)
                RoundedRectangle(cornerRadius: 14)
                    .stroke(boxColor, lineWidth: 3)
                    .shadow(color: .black.opacity(0.4), radius: 4)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .animation(.smooth(duration: 0.25), value: scanner.displayBox)
        .allowsHitTesting(false)
    }

    private var boxColor: Color {
        switch scanner.phase {
        case .found: .green
        case .duplicate: .orange
        case .recognizing: .yellow
        default: .white
        }
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

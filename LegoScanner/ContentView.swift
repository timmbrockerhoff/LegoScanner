import SwiftUI
import PhotosUI

struct ContentView: View {
    @State private var image: UIImage?
    @State private var items: [BrickognizeResponse.Item] = []
    @State private var measuredColor: SIMD3<Double>?
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?

    private let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)

    var body: some View {
        NavigationStack {
            Group {
                if image == nil {
                    ContentUnavailableView {
                        Label("Kein Teil gescannt", systemImage: "camera.viewfinder")
                    } description: {
                        Text("Fotografiere ein einzelnes LEGO-Teil vor einem ruhigen Hintergrund.")
                    }
                } else {
                    resultList
                }
            }
            .navigationTitle("Scanner")
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Mediathek", systemImage: "photo.on.rectangle")
                    }
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("Foto aufnehmen", systemImage: "camera") { showCamera = true }
                        .buttonStyle(.glassProminent)
                        .disabled(!cameraAvailable)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { recognize($0) }.ignoresSafeArea()
            }
            .onChange(of: photoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let picked = UIImage(data: data) {
                        recognize(picked)
                    }
                    photoItem = nil
                }
            }
        }
    }

    private var resultList: some View {
        List {
            if let image {
                Section {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 260)
                        .clipShape(.rect(cornerRadius: 16))
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if isLoading {
                Section {
                    LabeledContent("Teil wird erkannt") { ProgressView() }
                }
            } else if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } else if !items.isEmpty {
                Section {
                    ForEach(items.prefix(3)) { ResultRow(item: $0, measuredColor: measuredColor) }
                } header: {
                    Text("Treffer")
                } footer: {
                    Text("Teileerkennung: Brickognize · Farbdaten: Rebrickable")
                }
            }
        }
        .animation(.default, value: isLoading)
    }

    private func recognize(_ picked: UIImage) {
        let upright = picked.uprightResized(maxSide: 1024)
        image = upright
        items = []
        measuredColor = nil
        errorText = nil
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let response = try await Brickognize.recognize(upright)
                measuredColor = response.bounding_box.flatMap { upright.medianColor(in: $0.normalized) }
                items = response.items
                if items.isEmpty { errorText = "Kein Teil erkannt. Versuch es mit einem anderen Foto." }
            } catch {
                errorText = "Erkennung fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }
}

private struct ResultRow: View {
    let item: BrickognizeResponse.Item
    let measuredColor: SIMD3<Double>?

    @State private var colors: [LegoColor] = []
    @State private var color: LegoColor?

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: item.img_url) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                .frame(width: 56, height: 56)
                .padding(4)
                .background(.background.secondary, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.headline)
                Text("Teil \(item.id) · \(item.score, format: .percent.precision(.fractionLength(0)))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !colors.isEmpty {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(color?.swatch ?? .clear)
                            .strokeBorder(.separator)
                            .frame(width: 14, height: 14)
                        Picker("Farbe", selection: $color) {
                            ForEach(colors) { Text($0.name).tag(Optional($0)) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                Gauge(value: item.score) { Text("Übereinstimmung") }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .labelsHidden()
                    .tint(item.score > 0.7 ? .green : .orange)
            }
            Spacer(minLength: 0)
            Link(destination: item.bricklinkURL(colorID: color?.bricklinkID)) {
                Image(systemName: "arrow.up.forward.app")
                    .accessibilityLabel("Auf BrickLink öffnen")
            }
        }
        .buttonStyle(.borderless)
        .task(id: item.id) {
            colors = Rebrickable.colors(forPart: item.id)
            color = measuredColor.flatMap { colors.best(for: $0) } ?? colors.first
        }
    }
}

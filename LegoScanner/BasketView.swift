import SwiftUI

struct BasketView: View {
    @Bindable var basket: Basket
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Group {
                if basket.items.isEmpty {
                    ContentUnavailableView("Warenkorb ist leer", systemImage: "basket",
                                           description: Text("Gescannte Teile landen hier."))
                } else {
                    List {
                        Section {
                            ForEach($basket.items) { BasketRow(item: $0) }
                                .onDelete { basket.items.remove(atOffsets: $0) }
                        } header: {
                            Text(basket.totalCount == 1 ? "1 Teil" : "\(basket.totalCount) Teile, \(basket.items.count) verschiedene")
                        } footer: {
                            Text("Teileerkennung: Brickognize · Farbdaten: Rebrickable")
                        }
                    }
                }
            }
            .navigationTitle("Warenkorb")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Leeren", systemImage: "trash", role: .destructive) { confirmClear = true }
                        .disabled(basket.items.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig", systemImage: "checkmark") { dismiss() }
                }
            }
            .confirmationDialog("Alle Teile aus dem Warenkorb entfernen?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Warenkorb leeren", role: .destructive) { basket.items.removeAll() }
            }
        }
    }
}

private struct BasketRow: View {
    @Binding var item: BasketItem

    var body: some View {
        let colors = Rebrickable.colors(forPart: item.partID)
        let color = colors.first { $0.id == item.colorID }

        HStack(spacing: 14) {
            AsyncImage(url: item.imageURL) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                .frame(width: 56, height: 56)
                .padding(4)
                .background(.background.secondary, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                Text("Teil \(item.partID)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !colors.isEmpty {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(color?.swatch ?? .clear)
                            .strokeBorder(.separator)
                            .frame(width: 14, height: 14)
                        Picker("Farbe", selection: $item.colorID) {
                            Text("Unbekannt").tag(Int?.none)
                            ForEach(colors) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                Stepper("\(item.count) Stück", value: $item.count, in: 1...999)
                    .font(.subheadline)
            }
            Link(destination: BrickLink.url(part: item.partID, colorID: color?.bricklinkID)) {
                Image(systemName: "arrow.up.forward.app")
                    .accessibilityLabel("Auf BrickLink öffnen")
            }
        }
        .buttonStyle(.borderless)
    }
}

import SwiftUI

struct BasketView: View {
    @Bindable var basket: Basket
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Group {
                if basket.items.isEmpty {
                    ContentUnavailableView("Kiste ist leer", systemImage: "shippingbox",
                                           description: Text("Gescannte Teile, die zu keinem deiner Sets gehören, landen hier."))
                } else {
                    List {
                        Section {
                            ForEach($basket.items) { BasketRow(item: $0) }
                                .onDelete { basket.items.remove(atOffsets: $0) }
                        } header: {
                            Text(basket.totalCount == 1 ? "1 Teil" : "\(basket.totalCount) Teile, \(basket.items.count) verschiedene")
                        } footer: {
                            Text("Teile- und Farbnamen: BrickLink")
                        }
                    }
                }
            }
            .navigationTitle("Kiste")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Leeren", systemImage: "trash", role: .destructive) { confirmClear = true }
                        .disabled(basket.items.isEmpty)
                }
            }
            .confirmationDialog("Alle Teile aus der Kiste entfernen?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Kiste leeren", role: .destructive) { basket.items.removeAll() }
            }
        }
    }
}

private struct BasketRow: View {
    @Binding var item: BasketItem

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: item.imageURL) { $0.resizable().scaledToFit() } placeholder: {
                Image(systemName: "cube").foregroundStyle(.tertiary)
            }
            .frame(width: 56, height: 56)
            .padding(4)
            .background(.background.secondary, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                Text("Teil \(item.partID)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                // ponytail: alle BrickLink-Farben zur Auswahl. Mit BrickLink-API-Zugang nur die Farben, die es für das Teil gibt.
                Picker("Farbe", selection: $item.colorID) {
                    Text("Unbekannt").tag(Int?.none)
                    ForEach(BrickLink.colors, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .onChange(of: item.colorID) { _, id in
                    item.colorName = BrickLink.colors.first { $0.id == id }?.name
                }
                Stepper("\(item.count) Stück", value: $item.count, in: 1...999)
                    .font(.subheadline)
            }
            Link(destination: BrickLink.url(part: item.partID, colorID: item.colorID)) {
                Image(systemName: "arrow.up.forward.app")
                    .accessibilityLabel("Auf BrickLink öffnen")
            }
        }
        .buttonStyle(.borderless)
    }
}

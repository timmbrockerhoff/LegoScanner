import SwiftUI

/// Einkaufen: Fehlteile aller Sets, nach Set gruppiert, als eine BrickLink-Wanted-List.
// ponytail: noch ohne Preise. Mit BrickLink-API: Preis pro Teil, Summe pro Set, „Lohnt sich das?“.
struct ShoppingView: View {
    @Bindable var store: SetStore

    private var missingTotal: Int { store.sets.reduce(0) { $0 + $1.missing.reduce(0) { $0 + $1.count } } }

    var body: some View {
        NavigationStack {
            Group {
                if store.sets.isEmpty {
                    ContentUnavailableView("Noch keine Sets", systemImage: "cart",
                                           description: Text("Füge unter „Sets“ ein Set hinzu. Seine fehlenden Teile erscheinen dann hier."))
                } else if missingTotal == 0 {
                    ContentUnavailableView("Alles komplett", systemImage: "checkmark.seal",
                                           description: Text("Deinen Sets fehlt kein Teil."))
                } else {
                    List {
                        ForEach(store.sets) { owned in
                            let missing = owned.missing
                            if !missing.isEmpty {
                                Section {
                                    ForEach(missing, id: \.part.key) { item in
                                        MissingRow(part: item.part, count: item.count)
                                    }
                                } header: {
                                    Text(owned.lego.name)
                                } footer: {
                                    Text("\(missing.reduce(0) { $0 + $1.count }) Teile fehlen")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Einkaufen")
            .safeAreaInset(edge: .bottom) {
                if missingTotal > 0 {
                    ShareLink(item: store.wantedListXML, subject: Text("BrickLink-Wanted-List")) {
                        Label("\(missingTotal) Teile als Wanted-List", systemImage: "cart")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .padding()
                }
            }
        }
    }
}

private struct MissingRow: View {
    let part: LegoSet.Part
    let count: Int

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: BrickLink.imageURL(part: part.part, colorID: part.colorId)) { $0.resizable().scaledToFit() } placeholder: {
                Image(systemName: "cube").foregroundStyle(.tertiary)
            }
            .frame(width: 44, height: 44)
            .padding(4)
            .background(.background.secondary, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(part.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text("\(part.color) · \(part.part)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(count)×").font(.headline).monospacedDigit()
        }
    }
}

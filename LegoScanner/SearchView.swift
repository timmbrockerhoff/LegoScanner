import SwiftUI

/// Suche: Teile in deinen Sets finden („Wo gehört die 3001 hin?“) und Sets per Nummer hinzufügen.
// ponytail: sucht nur in den eigenen Sets. Mit BrickLink-API: ganzer Katalog, Sets per Name.
struct SearchView: View {
    @Bindable var store: SetStore
    @State private var query = ""
    @State private var adding = false
    @State private var message: String?

    private struct Hit: Identifiable {
        let owned: OwnedSet
        let part: LegoSet.Part
        var id: String { owned.id + part.key }
        var found: Int { min(owned.found[part.key] ?? 0, part.qty) }
    }

    private var hits: [Hit] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        return store.sets.flatMap { owned in
            owned.lego.parts
                .filter { $0.part.lowercased().hasPrefix(q) || $0.name.lowercased().contains(q) || $0.color.lowercased().contains(q) }
                .map { Hit(owned: owned, part: $0) }
        }
    }

    /// Sieht die Eingabe wie eine Setnummer aus (4–6 Ziffern, optional "-1")?
    private var setNumber: String? {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.range(of: #"^\d{4,6}(-\d+)?$"#, options: .regularExpression) != nil ? q : nil
    }

    var body: some View {
        NavigationStack {
            List {
                if let no = setNumber, !store.sets.contains(where: { $0.lego.no == no || $0.lego.no == "\(no)-1" }) {
                    Section {
                        Button {
                            add(no)
                        } label: {
                            Label(adding ? "Lade Teileliste … (große Sets bis zu einer Minute)" : "Set \(no) hinzufügen", systemImage: "plus.circle.fill")
                        }
                        .disabled(adding)
                    } footer: {
                        if let message { Text(message) }
                    }
                }
                if !hits.isEmpty {
                    Section("In deinen Sets") {
                        ForEach(hits) { hit in
                            HStack(spacing: 14) {
                                AsyncImage(url: BrickLink.imageURL(part: hit.part.part, colorID: hit.part.colorId)) { $0.resizable().scaledToFit() } placeholder: {
                                    Image(systemName: "cube").foregroundStyle(.tertiary)
                                }
                                .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.part.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                    Text("\(hit.part.color) · \(hit.part.part)").font(.caption).foregroundStyle(.secondary)
                                    Text(hit.owned.lego.name).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(hit.found)/\(hit.part.qty)")
                                    .font(.subheadline).monospacedDigit()
                                    .foregroundStyle(hit.found >= hit.part.qty ? .green : .primary)
                            }
                        }
                    }
                }
            }
            .overlay {
                if query.isEmpty {
                    ContentUnavailableView("Teil oder Set suchen", systemImage: "magnifyingglass",
                                           description: Text("Teilenummer, Name oder Farbe findet Teile in deinen Sets. Eine Setnummer fügt das Set hinzu."))
                } else if hits.isEmpty && setNumber == nil {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Suche")
            .searchable(text: $query, prompt: "Teil, Farbe oder Setnummer")
            .onChange(of: query) { message = nil }
        }
    }

    private func add(_ no: String) {
        adding = true
        Task {
            do {
                try await store.add(number: no)
                message = "Hinzugefügt. Du findest es unter „Sets“."
            } catch {
                message = error.localizedDescription
            }
            adding = false
        }
    }
}

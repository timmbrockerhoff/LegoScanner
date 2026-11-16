import QuickLook
import SwiftUI

/// Meine Sets: Sets, die der Nutzer aus seiner gemischten Kiste zusammensucht.
struct SetsView: View {
    @Bindable var store: SetStore
    @State private var showAdd = false
    @State private var number = ""
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.sets.isEmpty {
                    ContentUnavailableView {
                        Label("Noch keine Sets", systemImage: "square.stack.3d.up")
                    } description: {
                        Text("Füge ein Set hinzu, das du aus deiner Kiste zusammensuchen willst. Gescannte Teile werden ihm dann automatisch zugeordnet.")
                    } actions: {
                        Button("Set hinzufügen") { showAdd = true }
                            .buttonStyle(.glassProminent)
                    }
                } else {
                    List {
                        Section {
                            ForEach(store.sets) { owned in
                                NavigationLink(value: owned.id) { SetRow(owned: owned) }
                            }
                            .onDelete { store.sets.remove(atOffsets: $0) }
                            .onMove { store.sets.move(fromOffsets: $0, toOffset: $1) }
                        } footer: {
                            Text("Gescannte Teile gehen an das oberste Set, das sie noch braucht, dann absteigend. Reihenfolge per Ziehen ändern. Was zu keinem Set gehört, landet in der Kiste.")
                        }
                    }
                }
            }
            .navigationTitle("Meine Sets")
            .navigationDestination(for: String.self) { SetDetailView(store: store, setNo: $0) }
            .toolbar {
                if store.sets.count > 1 {
                    ToolbarItem(placement: .topBarLeading) { EditButton() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Set hinzufügen", systemImage: "plus") { showAdd = true }
                        .disabled(adding)
                }
            }
            .overlay {
                if adding {
                    VStack(spacing: 8) {
                        ProgressView("Lade Teileliste …")
                        Text("Große Sets brauchen beim ersten Mal bis zu einer Minute.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: 280)
                    .glassEffect(in: .rect(cornerRadius: 24))
                }
            }
            .alert("Set hinzufügen", isPresented: $showAdd) {
                TextField("Setnummer, z. B. 10132", text: $number)
                    .keyboardType(.numbersAndPunctuation)
                Button("Hinzufügen") { add() }
                Button("Abbrechen", role: .cancel) { number = "" }
            } message: {
                Text("Die Nummer steht auf der Packung und auf der Anleitung.")
            }
            .alert("Set nicht verfügbar", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func add() {
        let no = number
        number = ""
        guard !no.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        adding = true
        Task {
            do { try await store.add(number: no) } catch { self.error = error.localizedDescription }
            adding = false
        }
    }
}

private struct SetRow: View {
    let owned: OwnedSet

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: URL(string: owned.lego.image)) { $0.resizable().scaledToFit() } placeholder: {
                Image(systemName: "shippingbox").foregroundStyle(.tertiary)
            }
            .frame(width: 72, height: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(owned.lego.name).font(.headline)
                Text("\(owned.lego.no.replacingOccurrences(of: "-1", with: "")) · \(String(owned.lego.year))")
                    .font(.subheadline).foregroundStyle(.secondary)
                ProgressView(value: owned.progress)
                Text("\(owned.foundCount) von \(owned.lego.totalCount) Teilen")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }
}

/// Ein Set: Fortschritt pro Bauabschnitt, Fehlteile kaufen.
struct SetDetailView: View {
    @Bindable var store: SetStore
    let setNo: String
    @State private var preview: URL?

    var body: some View {
        if let owned = store.sets.first(where: { $0.id == setNo }) {
            let status = owned.status()
            List {
                Section {
                    AsyncImage(url: URL(string: owned.lego.image)) { $0.resizable().scaledToFit() } placeholder: {
                        Color.clear
                    }
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 180)
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Gefunden", value: "\(owned.foundCount) von \(owned.lego.totalCount)")
                            .monospacedDigit()
                        ProgressView(value: owned.progress)
                    }
                }
                Section("Bauabschnitte") {
                    ForEach(Array(owned.lego.sections.enumerated()), id: \.offset) { index, section in
                        NavigationLink {
                            SectionPartsView(store: store, setNo: setNo, sectionIndex: index)
                        } label: {
                            SectionRow(section: section, status: status[index])
                        }
                    }
                }
                Section {
                    if let manuals = owned.lego.instructions, !manuals.isEmpty {
                        ForEach(manuals, id: \.url) { InstructionRow(manual: $0, preview: $preview) }
                    } else {
                        Label(owned.lego.instructions == nil ? "Wird beim nächsten Start geladen" : "Keine digitale Anleitung bei LEGO",
                              systemImage: "book.closed")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Bauanleitung")
                } footer: {
                    Text("Von lego.com. Einmal geöffnet, ist sie auch ohne Internet da.")
                }
                Section {
                    ShareLink(item: owned.wantedListXML, subject: Text("Fehlteile \(owned.lego.name)")) {
                        Label("Fehlteile als BrickLink-Wanted-List", systemImage: "cart")
                    }
                    .disabled(owned.missing.isEmpty)
                    Link(destination: BrickLink.url(set: owned.lego.no)) {
                        Label("Set auf BrickLink", systemImage: "arrow.up.forward.app")
                    }
                } footer: {
                    Text("\(owned.missing.reduce(0) { $0 + $1.count }) Teile fehlen. Die Liste lädst du bei BrickLink unter Wanted → Upload hoch.")
                }
            }
            .navigationTitle(owned.lego.name)
            .navigationBarTitleDisplayMode(.inline)
            .quickLookPreview($preview)
        } else {
            ContentUnavailableView("Set entfernt", systemImage: "square.stack.3d.up.slash")
        }
    }
}

/// Ein Heft der Bauanleitung: einmal laden (Caches), dann direkt in der Systemvorschau (Quick Look) öffnen.
private struct InstructionRow: View {
    let manual: LegoSet.Instruction
    @Binding var preview: URL?
    @State private var loading = false
    @State private var failed = false

    private var file: URL {
        // Dateiname = Heft-Titel, den zeigt Quick Look oben an (statt LEGOs Dateinummer)
        let name = manual.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " ")
        let id = URL(string: manual.url)?.deletingPathExtension().lastPathComponent ?? "0"
        return URL.cachesDirectory.appending(path: "instructions").appending(path: id).appending(path: "\(name).pdf")
    }

    var body: some View {
        Button {
            open()
        } label: {
            HStack {
                Label(manual.title, systemImage: "book")
                Spacer()
                if loading {
                    ProgressView()
                } else if failed {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        .accessibilityLabel("Laden fehlgeschlagen, erneut tippen")
                } else if FileManager.default.fileExists(atPath: file.path()) {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                        .accessibilityLabel("Auf dem Gerät")
                } else {
                    Text(manual.size.replacingOccurrences(of: "MB", with: " MB")).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(loading)
    }

    private func open() {
        if FileManager.default.fileExists(atPath: file.path()) { preview = file; return }
        guard let url = URL(string: manual.url) else { return }
        loading = true
        failed = false
        Task {
            defer { loading = false }
            do {
                let (temp, response) = try await URLSession.shared.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: temp, to: file)
                preview = file
            } catch {
                failed = true
            }
        }
    }
}

private struct SectionRow: View {
    let section: LegoSet.Section
    let status: OwnedSet.SectionStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(section.name).font(.headline)
                Spacer()
                if status.found == status.total {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .accessibilityLabel("Komplett")
                }
            }
            // Einheitlich für alle Sets: Schrittzahl, dazu ggf. Tüte/Teilmodell
            Text([section.steps.isEmpty ? "Ohne Bauschritte" : "\(section.steps.count) Schritte", section.bag]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary)
            ProgressView(value: status.progress)
            HStack {
                Text("\(status.found) von \(status.total) Teilen").monospacedDigit()
                Spacer()
                if let step = status.buildableStep, let last = status.lastStep, step < last {
                    Text(step == 0 ? "Noch kein Schritt baubar" : "Baubar bis Schritt \(step) von \(last)")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// Teile eines Bauabschnitts: was da ist, was fehlt. Anzahl lässt sich von Hand korrigieren.
private struct SectionPartsView: View {
    @Bindable var store: SetStore
    let setNo: String
    let sectionIndex: Int
    @State private var onlyMissing = true

    var body: some View {
        if let owned = store.sets.first(where: { $0.id == setNo }) {
            let section = owned.lego.sections[sectionIndex]
            let mine = owned.allocation()[sectionIndex]
            let info = Dictionary(owned.lego.parts.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            // Teile, die in keinem gelesenen Bauschritt stehen, wurden der Tüte nach Teil/Farbe zugeordnet (geschätzt)
            let readFromSteps = section.steps.flatMap(\.parts).reduce(into: [String: Int]()) { $0[$1.key, default: 0] += $1.qty }
            let rows = section.parts
                .filter { !onlyMissing || (mine[$0.key] ?? 0) < $0.qty }
                .sorted { (info[$0.key]?.name ?? "") < (info[$1.key]?.name ?? "") }
            List {
                Section {
                    Picker("Anzeigen", selection: $onlyMissing) {
                        Text("Fehlt").tag(true)
                        Text("Alle").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                Section {
                    if rows.isEmpty {
                        Label("Alle Teile da", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    ForEach(rows, id: \.key) { need in
                        if let part = info[need.key] {
                            PartRow(part: part, have: mine[need.key] ?? 0, need: need.qty,
                                    estimated: section.steps.isEmpty ? 0 : max(0, need.qty - (readFromSteps[need.key] ?? 0)),
                                    found: Binding(get: { owned.found[part.key] ?? 0 },
                                                   set: { store.setFound($0, key: part.key, in: setNo) }))
                        }
                    }
                } footer: {
                    Text("Mit + und − korrigierst du die gefundene Anzahl, z. B. für Teile, die du ohne Scannen gefunden hast.")
                }
            }
            .navigationTitle(section.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct PartRow: View {
    let part: LegoSet.Part
    let have: Int
    let need: Int
    let estimated: Int // davon nicht aus der Anleitung gelesen, sondern geschätzt
    @Binding var found: Int

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: BrickLink.imageURL(part: part.part, colorID: part.colorId)) { $0.resizable().scaledToFit() } placeholder: {
                Image(systemName: "cube").foregroundStyle(.tertiary)
            }
            .frame(width: 48, height: 48)
            .padding(4)
            .background(.background.secondary, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(part.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text("\(part.color) · \(part.part)").font(.caption).foregroundStyle(.secondary)
                if estimated > 0 {
                    Label(estimated == need ? "Tüte geschätzt" : "\(estimated) davon Tüte geschätzt", systemImage: "questionmark.circle")
                        .font(.caption2).foregroundStyle(.orange)
                        .help("Nicht direkt aus der Anleitung gelesen, sondern nach Teil und Farbe dieser Tüte zugeordnet")
                }
                Stepper(value: $found, in: 0...part.qty) {
                    Text("\(have) von \(need)")
                        .font(.subheadline).monospacedDigit()
                        .foregroundStyle(have >= need ? .green : .primary)
                }
            }
        }
    }
}

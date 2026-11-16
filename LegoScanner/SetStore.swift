import Foundation
import Observation

/// Ein LEGO-Set mit Teileliste und Bauabschnitten, wie das Backend es liefert (`GET /api/sets?no=`).
struct LegoSet: Codable, Hashable {
    struct Part: Codable, Hashable {
        let part: String      // BrickLink-Teilenummer
        let color: String     // BrickLink-Farbname
        let colorId: Int?
        let name: String
        let qty: Int
        let rgb: String?      // Farbwert (hex), für die Farbwahl der Erkennung auf dem Gerät
        var key: String { "\(part)|\(color)" }
    }
    struct Need: Codable, Hashable {
        let part: String
        let color: String
        let qty: Int
        var key: String { "\(part)|\(color)" }
    }
    struct Step: Codable, Hashable {
        let page: Int
        let step: Int
        let parts: [Need]
    }
    /// Bauabschnitt, z. B. eine Tüte oder ein Teilmodell der Anleitung.
    struct Section: Codable, Hashable {
        let name: String
        let bag: String
        let pages: String
        let steps: [Step]
        let parts: [Need]
    }

    let no: String
    let name: String
    let year: Int
    let image: String
    let parts: [Part]
    let sections: [Section]
    /// Bauanleitungen (PDF) von lego.com, ein Eintrag pro Heft. nil = noch nicht geladen (ältere gespeicherte Daten).
    let instructions: [Instruction]?

    struct Instruction: Codable, Hashable {
        let title: String
        let size: String
        let url: String
    }

    var totalCount: Int { parts.reduce(0) { $0 + $1.qty } }
}

/// Ein Set, das der Nutzer zusammensucht: was schon gefunden ist.
struct OwnedSet: Codable, Identifiable {
    let lego: LegoSet
    var found: [String: Int] = [:] // "Teil|Farbe" → gefunden
    var id: String { lego.no }

    var foundCount: Int { lego.parts.reduce(0) { $0 + min(found[$1.key] ?? 0, $1.qty) } }
    var progress: Double { Double(foundCount) / Double(max(lego.totalCount, 1)) }

    /// Gefundene Teile auf die Abschnitte verteilen, in Bau-Reihenfolge: Die Lok bekommt zuerst, was sie braucht.
    func allocation() -> [[String: Int]] {
        var left = found
        return lego.sections.map { section in
            var mine: [String: Int] = [:]
            for need in section.parts {
                let take = min(left[need.key] ?? 0, need.qty)
                mine[need.key, default: 0] += take
                left[need.key, default: 0] -= take
            }
            return mine
        }
    }

    struct SectionStatus {
        let found: Int
        let total: Int
        let buildableStep: Int?  // bis zu diesem Schritt sind alle Teile da (nil = Abschnitt ohne Schritte)
        let lastStep: Int?
        var progress: Double { Double(found) / Double(max(total, 1)) }
    }

    func status() -> [SectionStatus] {
        zip(lego.sections, allocation()).map { section, mine in
            let total = section.parts.reduce(0) { $0 + $1.qty }
            let have = section.parts.reduce(0) { $0 + min(mine[$1.key] ?? 0, $1.qty) }
            guard !section.steps.isEmpty else { return SectionStatus(found: have, total: total, buildableStep: nil, lastStep: nil) }
            var available = mine
            var buildable = 0
            stepLoop: for step in section.steps {
                for need in step.parts where (available[need.key] ?? 0) < need.qty { break stepLoop }
                for need in step.parts { available[need.key, default: 0] -= need.qty }
                buildable = step.step
            }
            return SectionStatus(found: have, total: total, buildableStep: buildable, lastStep: section.steps.last?.step)
        }
    }

    /// Noch fehlende Teile des ganzen Sets.
    var missing: [(part: LegoSet.Part, count: Int)] {
        lego.parts.compactMap { part in
            let count = part.qty - min(found[part.key] ?? 0, part.qty)
            return count > 0 ? (part, count) : nil
        }
    }

    /// BrickLink-Wanted-List (XML zum Hochladen unter „Wanted → Upload“).
    var wantedListXML: String {
        let items = missing.compactMap { item -> String? in
            guard let color = item.part.colorId else { return nil }
            return "<ITEM><ITEMTYPE>P</ITEMTYPE><ITEMID>\(item.part.part)</ITEMID><COLOR>\(color)</COLOR><MINQTY>\(item.count)</MINQTY></ITEM>"
        }
        return "<INVENTORY>\n" + items.joined(separator: "\n") + "\n</INVENTORY>"
    }
}

/// Die Sets des Nutzers. Wird bei jeder Änderung auf dem Gerät gespeichert.
@MainActor @Observable
final class SetStore {
    var sets: [OwnedSet] { didSet { save() } }

    @ObservationIgnored private let fileURL = URL.applicationSupportDirectory.appending(path: "sets-v1.json")

    init() {
        sets = (try? JSONDecoder().decode([OwnedSet].self, from: Data(contentsOf: fileURL))) ?? []
    }

    var setNumbers: [String] { sets.map(\.lego.no) }
    var totalFound: Int { sets.reduce(0) { $0 + $1.foundCount } }

    /// Fehlteile aller Sets als eine BrickLink-Wanted-List (gleiche Teile zusammengefasst).
    var wantedListXML: String {
        var counts: [String: (part: String, color: Int, count: Int)] = [:]
        for owned in sets {
            for item in owned.missing {
                guard let color = item.part.colorId else { continue }
                counts["\(item.part.part)|\(color)", default: (item.part.part, color, 0)].count += item.count
            }
        }
        let items = counts.values.sorted { $0.part < $1.part }.map {
            "<ITEM><ITEMTYPE>P</ITEMTYPE><ITEMID>\($0.part)</ITEMID><COLOR>\($0.color)</COLOR><MINQTY>\($0.count)</MINQTY></ITEM>"
        }
        return "<INVENTORY>\n" + items.joined(separator: "\n") + "\n</INVENTORY>"
    }

    func add(number: String) async throws {
        let set = try await Backend.fetchSet(number)
        guard !sets.contains(where: { $0.id == set.no }) else { return }
        sets.append(OwnedSet(lego: set)) // neue Sets unten: die Prioritäten oben bleiben, wie der Nutzer sie geordnet hat
    }

    /// Teilelisten und Bauabschnitte neu laden (z. B. verbesserte Abschnitte im Backend). Gefundenes bleibt erhalten.
    /// Kostet nichts: Das Backend antwortet aus dem Cache.
    func refresh() async {
        for owned in sets {
            guard let fresh = try? await Backend.fetchSet(owned.lego.no), fresh != owned.lego,
                  let index = sets.firstIndex(where: { $0.id == owned.id }) else { continue }
            sets[index] = OwnedSet(lego: fresh, found: sets[index].found)
        }
    }

    func setFound(_ count: Int, key: String, in setNo: String) {
        guard let index = sets.firstIndex(where: { $0.id == setNo }) else { return }
        sets[index].found[key] = max(0, count)
    }

    struct Assignment {
        let setName: String
        let sectionName: String
        let stillNeeded: Int
        let label: String
    }

    /// Gescanntes Teil dem obersten Set zuordnen, das es noch braucht. Die Form entscheidet, die Farbe kommt im Zweifel aus der
    /// Teileliste: Braucht das Set die Form nur in einer Farbe, zählt das Teil auch bei unsicher erkannter Farbe.
    /// nil = gehört zu keinem Set (landet in der Kiste).
    func assign(_ detected: DetectedPart) -> Assignment? {
        let shape = Self.baseNumber(detected.partNo)
        var candidates: [(set: Int, part: LegoSet.Part)] = []
        for (index, owned) in sets.enumerated() {
            for part in owned.lego.parts where Self.baseNumber(part.part) == shape && (owned.found[part.key] ?? 0) < part.qty {
                candidates.append((index, part))
            }
        }
        let sameColor = candidates.filter { $0.part.color == detected.colorName }
        let colors = Set(candidates.map(\.part.color))
        let pool = !sameColor.isEmpty ? sameColor : (colors.count == 1 ? candidates : [])
        // Mehrere Sets brauchen das Teil: das oberste in „Meine Sets“ zuerst (Reihenfolge = Priorität des Nutzers)
        guard let pick = pool.min(by: { $0.set < $1.set }) else { return nil }

        sets[pick.set].found[pick.part.key, default: 0] += 1
        let owned = sets[pick.set]
        let count = owned.found[pick.part.key] ?? 0
        // Abschnitt, in den dieses Teil fällt: der erste, der es nach der Verteilung noch nicht voll hatte
        var before = count - 1
        var sectionName = owned.lego.sections.first?.name ?? owned.lego.name
        for section in owned.lego.sections {
            let need = section.parts.first { $0.key == pick.part.key }?.qty ?? 0
            if before < need { sectionName = section.name; break }
            before -= need
        }
        let still = pick.part.qty - count
        let short = owned.lego.no.replacingOccurrences(of: "-1", with: "")
        return Assignment(setName: owned.lego.name, sectionName: sectionName, stillNeeded: still,
                          label: "\(pick.part.name) → \(sectionName) (\(short))" + (still > 0 ? ", noch \(still)" : ", komplett"))
    }

    /// "3062b" → "3062": BrickLink-Varianten derselben Form vergleichen.
    static func baseNumber(_ no: String) -> String {
        var s = Substring(no)
        while let last = s.last, last.isLetter, s.dropLast().last?.isNumber == true { s = s.dropLast() }
        return String(s)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(sets).write(to: fileURL, options: .atomic)
    }
}

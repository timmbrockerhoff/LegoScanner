import Foundation
import Observation

struct BasketItem: Codable, Identifiable {
    var id = UUID()
    let partID: String     // BrickLink-Teilenummer
    let name: String
    var colorID: Int?      // BrickLink-Farb-ID
    var colorName: String?
    var count = 1

    var imageURL: URL? { BrickLink.imageURL(part: partID, colorID: colorID) }
}

/// Gescannte Teile. Wird bei jeder Änderung auf dem Gerät gespeichert.
@MainActor @Observable
final class Basket {
    var items: [BasketItem] { didSet { save() } }

    var totalCount: Int { items.reduce(0) { $0 + $1.count } }

    // v2: seit dem Wechsel auf BrickLink-Farb-IDs (vorher Rebrickable-IDs, nicht kompatibel)
    @ObservationIgnored private let fileURL = URL.applicationSupportDirectory.appending(path: "basket-v2.json")

    init() {
        items = (try? JSONDecoder().decode([BasketItem].self, from: Data(contentsOf: fileURL))) ?? []
    }

    func contains(part: String) -> Bool { items.contains { $0.partID == part } }

    /// Gleiches Teil in gleicher Farbe → Anzahl +1, sonst neuer Eintrag. Zuletzt gescannt steht oben.
    func add(_ part: DetectedPart) {
        var item = BasketItem(partID: part.partNo, name: part.name, colorID: part.colorId, colorName: part.colorName)
        if let index = items.firstIndex(where: { $0.partID == item.partID && $0.colorID == item.colorID }) {
            item = items.remove(at: index)
            item.count += 1
        }
        items.insert(item, at: 0)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: fileURL, options: .atomic)
    }
}

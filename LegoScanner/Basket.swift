import Foundation
import Observation

struct BasketItem: Codable, Identifiable {
    var id = UUID()
    let partID: String
    let name: String
    let imageURL: URL?
    var colorID: Int?   // Rebrickable-Farb-ID
    var count = 1
}

/// Gescannte Teile. Wird bei jeder Änderung auf dem Gerät gespeichert.
@MainActor @Observable
final class Basket {
    var items: [BasketItem] { didSet { save() } }

    var totalCount: Int { items.reduce(0) { $0 + $1.count } }

    @ObservationIgnored private let fileURL = URL.applicationSupportDirectory.appending(path: "basket.json")

    init() {
        items = (try? JSONDecoder().decode([BasketItem].self, from: Data(contentsOf: fileURL))) ?? []
    }

    /// Gleiches Teil in gleicher Farbe → Anzahl +1, sonst neuer Eintrag. Zuletzt gescannt steht oben.
    func add(_ scan: ScanResult) {
        var item = BasketItem(partID: scan.item.id, name: scan.item.name, imageURL: scan.item.img_url, colorID: scan.color?.id)
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

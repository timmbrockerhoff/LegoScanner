import SwiftUI

/// Tab-Leiste der App. Sets ist der Start, die Kamera läuft nur im Scan-Tab.
struct RootView: View {
    enum Tab: Hashable { case sets, scan, box, shop, search }

    @State private var tab = Tab.sets
    @State private var basket = Basket()
    @State private var sets = SetStore()
    @State private var scanner = Scanner()

    var body: some View {
        TabView(selection: $tab) {
            SwiftUI.Tab("Sets", systemImage: "square.stack.3d.up", value: .sets) {
                SetsView(store: sets)
            }
            SwiftUI.Tab("Scannen", systemImage: "viewfinder", value: .scan) {
                ScannerView(scanner: scanner, basket: basket, sets: sets)
            }
            SwiftUI.Tab("Kiste", systemImage: "shippingbox", value: .box) {
                BasketView(basket: basket)
            }
            .badge(basket.totalCount)
            SwiftUI.Tab("Einkaufen", systemImage: "cart", value: .shop) {
                ShoppingView(store: sets)
            }
            SwiftUI.Tab("Suche", systemImage: "magnifyingglass", value: .search, role: .search) {
                SearchView(store: sets)
            }
        }
        .task {
            scanner.basket = basket
            scanner.sets = sets
            await sets.refresh()
        }
    }
}

import SwiftUI

@main
struct LegoScannerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task { await Rebrickable.refresh() }
        }
    }
}

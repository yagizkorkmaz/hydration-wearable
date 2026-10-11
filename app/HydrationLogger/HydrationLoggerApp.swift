import SwiftUI

@main
struct HydrationLoggerApp: App {
    @Environment(\.scenePhase) private var scenePhase

    // BLE yoneticisi uygulama yasam dongusu boyunca tek ornek olarak yasar.
    @StateObject private var ble = BLEManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ble)
        }
        .onChange(of: scenePhase) { _, phase in
            // Arka plana gecerken tamponu diske bosalt, veri kaybi olmasin.
            if phase != .active {
                DataLogger.shared.flush()
            }
        }
    }
}

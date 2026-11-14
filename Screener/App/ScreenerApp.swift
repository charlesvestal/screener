import SwiftUI

@main
struct ScreenerApp: App {
    init() { Log.app.info("Screener launched") }
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "previewControlMenu") {
                FloatingMenuPreview()
            } else {
                HostListView()
            }
            #else
            HostListView()
            #endif
        }
    }
}

import SwiftUI

@main
struct ScreenerApp: App {
    init() { Log.app.info("Screener launched") }
    var body: some Scene {
        WindowGroup { HostListView() }
    }
}

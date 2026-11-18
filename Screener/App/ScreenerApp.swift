import SwiftData
import SwiftUI

@main
struct ScreenerApp: App {
    /// Saved hosts (Hosts/SavedHost.swift). If the store can't be opened the
    /// app still runs, with an in-memory store for this launch.
    let hosts: ModelContainer

    init() {
        Log.app.info("Screener launched")
        // A session that never ended (crash / killed while suspended) may have
        // left a saved Mac's session settings in place of the defaults.
        HostSettingsOverlay.recoverAfterCrash()
        do {
            hosts = try HostStore.makeContainer()
        } catch {
            Log.hosts.error("couldn't open the hosts store (\(error)); using an in-memory store")
            do { hosts = try HostStore.makeContainer(inMemory: true) } catch {
                fatalError("in-memory hosts store: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "previewCoach") {
                // Screenshot harness (GestureCoach): the overlay alone, over a
                // stand-in desktop, no Mac needed.
                ZStack {
                    LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .ignoresSafeArea()
                    GestureCoachOverlay(onDismiss: {})
                }
            } else if UserDefaults.standard.bool(forKey: "previewHelp") {
                // Screenshot harness (HelpView): no Mac, no session needed.
                HelpView()
            } else if UserDefaults.standard.bool(forKey: "previewControlMenu") {
                FloatingMenuPreview()
            } else {
                HostListView()
            }
            #else
            HostListView()
            #endif
        }
        .modelContainer(hosts)
    }
}

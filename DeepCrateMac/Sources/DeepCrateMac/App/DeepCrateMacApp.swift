import AppKit
import SwiftUI

final class DeepCrateAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct DeepCrateMacApp: App {
    @NSApplicationDelegateAdaptor(DeepCrateAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup("DeepCrate") {
            RootView()
                .environmentObject(appState)
                .environmentObject(settings)
        }
        .defaultSize(width: 1180, height: 760)

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}

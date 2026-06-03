import SwiftUI

@main
struct TimeboxStudioApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(appState)
                .frame(minWidth: 940, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Refresh Bluetooth Devices") {
                    appState.refreshDevices()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}

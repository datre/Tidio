import SwiftUI

@main
struct TidioApp: App {
    @StateObject private var libraryViewModel = LibraryViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(libraryViewModel)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Library Access") {
                    Task { await libraryViewModel.requestAuthorization() }
                }
            }
        }

        Settings {
            SettingsView()
        }
    }
}

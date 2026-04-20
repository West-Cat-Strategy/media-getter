import SwiftUI

@main
struct MediaGetterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootSplitView(appState: appState)
                .frame(minWidth: 1180, minHeight: 760)
                .task {
                    await appState.bootstrap()
                }
        }
        .commands {
            MediaGetterCommands(appState: appState)
        }

        Settings {
            SettingsView(appState: appState)
                .frame(width: 560, height: 520)
                .padding()
        }
    }
}


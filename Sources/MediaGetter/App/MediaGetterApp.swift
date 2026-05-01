import SwiftUI

@main
struct MediaGetterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @State private var appUpdateManager = AppUpdateManager()

    var body: some Scene {
        WindowGroup {
            RootSplitView(appState: appState)
                .frame(
                    minWidth: LayoutMetrics.minimumWindowWidth,
                    minHeight: LayoutMetrics.minimumWindowHeight
                )
                .task {
                    await appState.bootstrap()
                }
        }
        .commands {
            MediaGetterCommands(appState: appState, appUpdateManager: appUpdateManager)
        }

        Settings {
            SettingsView(appState: appState, appUpdateManager: appUpdateManager)
                .frame(minWidth: 520, minHeight: 480)
                .padding()
        }
    }
}

import AppKit
import SwiftUI

struct MediaGetterCommands: Commands {
    let appState: AppState
    let appUpdateManager: AppUpdateManager

    var body: some Commands {
        SidebarCommands()

        CommandGroup(replacing: .appInfo) {
            Button("About MediaGetter") {
                MediaGetterAboutPanel.show()
            }
        }

        CommandGroup(after: .appInfo) {
            Button(appUpdateManager.primaryUpdateActionTitle) {
                appUpdateManager.performPrimaryUpdateAction()
            }
            .disabled(!appUpdateManager.canPerformPrimaryUpdateAction)
        }

        CommandMenu("Media Studio") {
            Button("Paste URL") {
                appState.pasteURLFromClipboard()
            }
            .keyboardShortcut("v", modifiers: [.command, .option])

            Button("Open File") {
                appState.openMediaFileForCurrentSection()
            }
            .keyboardShortcut("o", modifiers: [.command, .option])

            Divider()

            Button("Start") {
                Task { await appState.startPrimaryAction() }
            }
            .keyboardShortcut(.return, modifiers: [.command])

            Button("Cancel Selected Job") {
                appState.cancelSelectedJob()
            }
            .keyboardShortcut(".", modifiers: [.command])

            Button("Reveal Output") {
                appState.revealSelectedOutput()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}

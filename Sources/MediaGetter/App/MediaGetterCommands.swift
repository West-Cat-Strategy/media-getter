import SwiftUI

struct MediaGetterCommands: Commands {
    let appState: AppState

    var body: some Commands {
        SidebarCommands()

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


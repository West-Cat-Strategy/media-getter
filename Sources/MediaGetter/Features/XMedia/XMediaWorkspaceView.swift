import SwiftUI

struct XMediaWorkspaceView: View {
    @Bindable var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                WorkspaceHeader(
                    title: "X Media",
                    subtitle: "Download all media from a public X profile's Media tab."
                )

                StudioCard {
                    Text("Profile details")
                        .font(.headline)

                    HStack {
                        Text("@")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        TextField("username", text: $appState.xMediaDraft.handle)
                            .textFieldStyle(.plain)
                            .studioInputStyle()
                            .font(.title3)
                    }

                    Picker("Browser for cookies", selection: $appState.xMediaDraft.browser) {
                        ForEach(XBrowser.allCases) { browser in
                            Text(browser.title).tag(browser)
                        }
                    }
                    .pickerStyle(.menu)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cookie file path")
                            .font(.subheadline)
                        TextField("~/twitter-cookies.txt", text: $appState.xMediaDraft.cookieFilePath)
                            .textFieldStyle(.plain)
                            .studioInputStyle()
                    }

                    PathPickerRow(
                        title: "Destination folder",
                        path: appState.xMediaDraft.destinationDirectoryPath
                    ) {
                        appState.chooseDestinationFolder(for: .xMedia)
                    }

                    HStack {
                        Button("Start Download") {
                            Task { await appState.startPrimaryAction() }
                        }
                        .buttonStyle(InteractiveButtonStyle())

                        Button("Stop / Cancel") {
                            appState.cancelSelectedJob()
                        }
                        .buttonStyle(InteractiveButtonStyle())

                        Button("Open Folder") {
                            appState.revealSelectedOutput()
                        }
                        .disabled(appState.xMediaDraft.destinationDirectoryPath.isEmpty)
                        .buttonStyle(InteractiveButtonStyle())
                    }
                }

                StudioCard {
                    Text("Workflow summary")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Export cookies from \(appState.xMediaDraft.browser.title)", systemImage: "1.circle")
                        Label("Verify auth_token and ct0", systemImage: "2.circle")
                        Label("Download media via gallery-dl", systemImage: "3.circle")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct DownloadWorkspaceView: View {
    @Bindable var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                WorkspaceHeader(
                    title: "Download",
                    subtitle: "Paste a public media URL, inspect the available formats, and add a clean download job to the queue."
                )

                StudioCard {
                    Text("Paste or drop a public media URL")
                        .font(.headline)

                    TextField("https://example.com/video", text: $appState.downloadDraft.urlString)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(AccessibilityID.downloadURLField)

                    HStack {
                        Button("Paste URL") {
                            appState.pasteURLFromClipboard()
                        }

                        Button(appState.downloadDraft.isProbing ? "Inspecting…" : "Inspect URL") {
                            Task { await appState.probeDownloadURL() }
                        }
                        .disabled(appState.downloadDraft.isProbing)
                        .accessibilityIdentifier(AccessibilityID.downloadInspectButton)

                        Spacer()

                        Button("Show Metadata") {
                            appState.inspectorMode = .metadata
                        }
                        .disabled(appState.downloadDraft.metadata == nil)
                    }
                }
                .onDrop(of: [UTType.url.identifier, UTType.fileURL.identifier, UTType.text.identifier], isTargeted: nil) { providers in
                    DropSupport.handleURLOrTextProviders(
                        providers,
                        onFile: { fileURL in
                            appState.downloadDraft.urlString = fileURL.absoluteString
                        },
                        onText: { string in
                            appState.downloadDraft.urlString = string
                        }
                    )
                }

                StudioCard {
                    Text("Starter presets")
                        .font(.headline)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                        ForEach(OutputPresetID.starterPresets) { preset in
                            PresetTile(
                                preset: preset,
                                isSelected: appState.downloadDraft.selectedPreset == preset
                            ) {
                                appState.applyStarterPreset(preset)
                            }
                        }
                    }
                }

                if let metadata = appState.downloadDraft.metadata {
                    MetadataSummaryCard(metadata: metadata)

                    StudioCard {
                        Text("Download options")
                            .font(.headline)

                        Picker("Output preset", selection: $appState.downloadDraft.selectedPreset) {
                            ForEach(OutputPresetID.downloadPresets) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }

                        Picker("Format", selection: $appState.downloadDraft.selectedFormatID) {
                            Text("Automatic (best available)")
                                .tag("bestvideo*+bestaudio/best")

                            ForEach(metadata.formats) { format in
                                Text(format.displayName)
                                    .tag(format.id)
                            }
                        }

                        Toggle("Include subtitles when available", isOn: $appState.downloadDraft.includeSubtitles)

                        TextField("Filename template", text: $appState.downloadDraft.filenameTemplate)

                        PathPickerRow(
                            title: "Destination folder",
                            path: appState.downloadDraft.destinationDirectoryPath
                        ) {
                            appState.chooseDestinationFolder(for: .download)
                        }

                        Button("Add Download Job") {
                            appState.enqueueDownload()
                        }
                        .accessibilityIdentifier(AccessibilityID.downloadQueueButton)
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
        }
    }
}


import SwiftUI
import UniformTypeIdentifiers

struct ConvertWorkspaceView: View {
    @Bindable var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                WorkspaceHeader(
                    title: "Convert",
                    subtitle: "Open a local file or a previous output, choose a small set of good presets, and keep advanced codec overrides tucked away until you need them."
                )

                StudioCard {
                    Text("Source file")
                        .font(.headline)

                    if let inputURL = appState.convertDraft.inputURL {
                        Text(inputURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No file selected yet.")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button("Open File") {
                            appState.openMediaFileForCurrentSection()
                        }
                        .accessibilityIdentifier(AccessibilityID.convertOpenButton)

                        if appState.convertDraft.inputURL != nil {
                            Button("Show Metadata") {
                                appState.inspectorMode = .metadata
                            }
                        }
                    }
                }
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                    DropSupport.handleURLOrTextProviders(
                        providers,
                        onFile: { fileURL in
                            Task { await appState.loadLocalFile(fileURL, for: .convert) }
                        },
                        onText: { _ in }
                    )
                }

                if let metadata = appState.convertDraft.metadata {
                    MetadataSummaryCard(metadata: metadata)
                }

                StudioCard {
                    Text("Preset")
                        .font(.headline)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                        ForEach(OutputPresetID.convertPresets) { preset in
                            PresetTile(
                                preset: preset,
                                isSelected: appState.convertDraft.selectedPreset == preset
                            ) {
                                appState.convertDraft.selectedPreset = preset
                                appState.inspectorMode = .preset
                            }
                        }
                    }

                    PathPickerRow(
                        title: "Destination folder",
                        path: appState.convertDraft.destinationDirectoryPath
                    ) {
                        appState.chooseDestinationFolder(for: .convert)
                    }

                    DisclosureGroup("Advanced options", isExpanded: $appState.convertDraft.showAdvanced) {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Container override (optional)", text: $appState.convertDraft.containerOverride)
                            TextField("Video codec override (optional)", text: $appState.convertDraft.videoCodecOverride)
                            TextField("Audio codec override (optional)", text: $appState.convertDraft.audioCodecOverride)
                            TextField("Audio bitrate override (optional)", text: $appState.convertDraft.audioBitrateOverride)
                        }
                        .textFieldStyle(.roundedBorder)
                        .padding(.top, 12)
                    }

                    Button("Add Convert Job") {
                        appState.enqueueConvert()
                    }
                    .disabled(appState.convertDraft.inputURL == nil)
                    .accessibilityIdentifier(AccessibilityID.convertQueueButton)
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
        }
    }
}


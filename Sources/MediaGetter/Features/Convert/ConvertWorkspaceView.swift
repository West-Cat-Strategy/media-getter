import SwiftUI

struct ConvertWorkspaceView: View {
    @Bindable var appState: AppState

    var body: some View {
        WorkspaceContainer {
            WorkspaceHeader(
                title: "Convert",
                subtitle: "Choose a source file, pick an output preset, then add the conversion to the queue."
            )

            WorkspaceSection(title: "Source") {
                if let inputURL = appState.convertDraft.inputURL {
                    CompactPathText(path: inputURL.path)
                } else {
                    Text("No file selected yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                AdaptiveButtonRow {
                    Button("Open File") {
                        appState.openMediaFileForCurrentSection()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(AccessibilityID.convertOpenButton)

                    if appState.convertDraft.inputURL != nil {
                        Button("Show Metadata") {
                            appState.inspectorMode = .metadata
                        }
                    }
                }
            }

            if let metadata = appState.convertDraft.metadata {
                MetadataSummaryCard(metadata: metadata)
            }

            WorkspaceSection(title: "Output") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 12)], spacing: 12) {
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

                DisclosureGroup("Advanced codec options", isExpanded: $appState.convertDraft.showAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Container override (optional)", text: $appState.convertDraft.containerOverride)
                        TextField("Video codec override (optional)", text: $appState.convertDraft.videoCodecOverride)
                        TextField("Audio codec override (optional)", text: $appState.convertDraft.audioCodecOverride)
                        TextField("Audio bitrate override (optional)", text: $appState.convertDraft.audioBitrateOverride)
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 8)
                }

                Toggle(
                    "Generate subtitles after export",
                    isOn: Binding(
                        get: { appState.convertDraft.subtitleWorkflow.generatesSubtitles },
                        set: {
                            appState.convertDraft.subtitleWorkflow.sourcePolicy = $0 ? .generateOnly : .off
                        }
                    )
                )
                .accessibilityIdentifier(AccessibilityID.convertSubtitleToggle)

                if appState.convertDraft.subtitleWorkflow.generatesSubtitles {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Generated output", selection: $appState.convertDraft.subtitleWorkflow.outputFormat) {
                            ForEach(TranscriptionOutputFormat.subtitleFormats) { format in
                                Text(format.title).tag(format)
                            }
                        }

                        Toggle(
                            "Burn captions into exported video",
                            isOn: $appState.convertDraft.subtitleWorkflow.burnInVideo
                        )

                        if appState.convertDraft.selectedPreset.audioOnly {
                            Text("Caption burn-in only applies to video presets.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Label(
                            appState.transcriptionRuntimeSummary,
                            systemImage: appState.isTranscriptionReady ? "waveform" : "exclamationmark.triangle"
                        )
                        .font(.subheadline.weight(.semibold))

                        Text(appState.transcriptionRuntimeDetail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 2)
                }

                Button("Add Convert Job") {
                    appState.enqueueConvert()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    appState.convertDraft.inputURL == nil
                        || (appState.convertDraft.subtitleWorkflow.needsLocalRuntime && !appState.isTranscriptionReady)
                        || (appState.convertDraft.subtitleWorkflow.burnInVideo && appState.convertDraft.selectedPreset.audioOnly)
                )
                .accessibilityIdentifier(AccessibilityID.convertQueueButton)
            }
        }
    }
}

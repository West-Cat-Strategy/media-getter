import SwiftUI

struct TranscribeWorkspaceView: View {
    @Bindable var appState: AppState

    var body: some View {
        WorkspaceContainer {
                WorkspaceHeader(
                    title: "Transcribe",
                    subtitle: "Open a local or previously downloaded media file, then create a local English transcript with bundled Whisper output as text, SRT, or VTT."
                )

                StudioCard {
                    Text("Source media")
                        .font(.headline)

                    if let inputURL = appState.transcribeDraft.inputURL {
                        Text(inputURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Open a local media file to prepare a transcript.")
                            .foregroundStyle(.secondary)
                    }

                    AdaptiveButtonRow {
                        Button("Open File") {
                            appState.selectedSection = .transcribe
                            appState.openMediaFileForCurrentSection()
                        }
                        .accessibilityIdentifier(AccessibilityID.transcribeOpenButton)

                        if appState.transcribeDraft.inputURL != nil {
                            Button("Show Metadata") {
                                appState.inspectorMode = .metadata
                            }
                        }
                    }
                }
                if let metadata = appState.transcribeDraft.metadata {
                    MetadataSummaryCard(metadata: metadata)
                }

                StudioCard {
                    Label(appState.transcriptionRuntimeSummary, systemImage: appState.isTranscriptionReady ? "waveform" : "exclamationmark.triangle")
                        .font(.headline)

                    Text(appState.transcriptionRuntimeDetail)
                        .foregroundStyle(.secondary)

                    Picker("Output format", selection: $appState.transcribeDraft.outputFormat) {
                        ForEach(TranscriptionOutputFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.transcribeFormatPicker)

                    Text("Selected: \(appState.transcribeDraft.outputFormat.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityID.transcribeFormatValue)

                    PathPickerRow(
                        title: "Destination folder",
                        path: appState.transcribeDraft.destinationDirectoryPath
                    ) {
                        appState.chooseDestinationFolder(for: .transcribe)
                    }

                    Button("Add Transcription Job") {
                        appState.enqueueTranscribe()
                    }
                    .disabled(appState.transcribeDraft.inputURL == nil || !appState.isTranscriptionReady)
                    .accessibilityIdentifier(AccessibilityID.transcribeQueueButton)
                }
        }
    }
}

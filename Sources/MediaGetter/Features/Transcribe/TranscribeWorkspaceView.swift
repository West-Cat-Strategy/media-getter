import SwiftUI

struct TranscribeWorkspaceView: View {
    @Bindable var appState: AppState

    var body: some View {
        WorkspaceContainer {
            WorkspaceHeader(
                title: "Transcribe",
                subtitle: "Create a local transcript or subtitle file from downloaded or local media."
            )

            WorkspaceSection(title: "Source") {
                if let inputURL = appState.transcribeDraft.inputURL {
                    CompactPathText(path: inputURL.path)
                } else {
                    Text("Open a local media file to prepare a transcript.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                AdaptiveButtonRow {
                    Button("Open File") {
                        appState.selectedSection = .transcribe
                        appState.openMediaFileForCurrentSection()
                    }
                    .buttonStyle(.borderedProminent)
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

            WorkspaceSection(title: "Output") {
                Label(appState.transcriptionRuntimeSummary, systemImage: appState.isTranscriptionReady ? "waveform" : "exclamationmark.triangle")
                    .font(.headline)

                Text(appState.transcriptionRuntimeDetail)
                    .font(.subheadline)
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
                .buttonStyle(.borderedProminent)
                .disabled(appState.transcribeDraft.inputURL == nil || !appState.isTranscriptionReady)
                .accessibilityIdentifier(AccessibilityID.transcribeQueueButton)
            }
        }
    }
}

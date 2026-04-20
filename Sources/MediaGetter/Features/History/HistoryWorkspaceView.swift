import SwiftUI

struct HistoryWorkspaceView: View {
    let appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                WorkspaceHeader(
                    title: "History",
                    subtitle: "Jump back into recent media work, reveal exported files, or reload a previous source into the right workflow."
                )

                if appState.historyStore.entries.isEmpty {
                    StudioCard {
                        Text("No recent jobs")
                            .font(.headline)
                        Text("Completed jobs will appear here so you can rerun them quickly.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(appState.historyStore.entries) { entry in
                            StudioCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(entry.title)
                                        .font(.headline)
                                    Text(entry.subtitle)
                                        .foregroundStyle(.secondary)
                                    if entry.isAutoSubtitleJob {
                                        Text("Linked auto-subtitle job")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    if let outputPath = entry.outputPath {
                                        Text(outputPath)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    HStack {
                                        Button("Load into Workspace") {
                                            appState.loadHistoryEntryIntoWorkspace(entry)
                                        }

                                        if let transcribeURL = appState.transcriptionSourceURL(for: entry) {
                                            Button("Transcribe") {
                                                appState.loadMediaIntoTranscribe(transcribeURL)
                                            }
                                        }

                                        if let outputURL = entry.outputURL {
                                            Button("Reveal") {
                                                FileHelpers.reveal(outputURL)
                                            }
                                        }

                                    }

                                    SubtitleArtifactSection(
                                        artifacts: entry.subtitleArtifacts,
                                        onPreview: { artifact in
                                            appState.historyStore.selectedEntryID = entry.id
                                            appState.previewArtifact(artifact)
                                        },
                                        onOpen: { artifact in
                                            appState.openTranscript(artifact.url)
                                        },
                                        onReveal: { artifact in
                                            FileHelpers.reveal(artifact.url)
                                        }
                                    )
                                }
                            }
                            .onTapGesture {
                                appState.historyStore.selectedEntryID = entry.id
                                appState.inspectorArtifactPath = nil
                            }
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.historyList)
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
        }
    }
}

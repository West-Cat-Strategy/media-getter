import SwiftUI

struct HistoryWorkspaceView: View {
    let appState: AppState

    var body: some View {
        WorkspaceContainer {
            WorkspaceHeader(
                title: "History",
                subtitle: "Reload recent work, reveal exports, or send finished media into another workflow."
            )

            if appState.historyStore.entries.isEmpty {
                WorkspaceSection(title: "No recent jobs") {
                    Text("Completed jobs will appear here so you can rerun them quickly.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(appState.historyStore.entries) { entry in
                        StudioCard {
                            VStack(alignment: .leading, spacing: 10) {
                                ViewThatFits(in: .horizontal) {
                                    HStack(alignment: .top) {
                                        Text(entry.title)
                                            .font(.headline)
                                            .lineLimit(2)
                                        Spacer()
                                        StatusBadge(status: entry.status)
                                    }

                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(entry.title)
                                            .font(.headline)
                                            .lineLimit(2)
                                        StatusBadge(status: entry.status)
                                    }
                                }
                                Text(entry.subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if entry.isAutoSubtitleJob {
                                    Text("Linked auto-subtitle job")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(entry.summary)
                                    .font(.subheadline)

                                if let outputPath = entry.outputPath {
                                    CompactPathText(path: outputPath)
                                }

                                AdaptiveButtonRow {
                                    if entry.canRerun {
                                        Button("Rerun") {
                                            appState.rerunHistoryEntry(entry)
                                        }
                                        .accessibilityIdentifier(AccessibilityID.historyEntryRerunButton)
                                    }

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
    }
}

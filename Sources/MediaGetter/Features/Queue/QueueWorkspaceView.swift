import SwiftUI

struct QueueWorkspaceView: View {
    @Bindable var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                WorkspaceHeader(
                    title: "Queue",
                    subtitle: "Keep downloads, transcodes, trims, and transcriptions in one place, inspect progress, and route finished media into the next workflow."
                )

                if appState.queueStore.jobs.isEmpty {
                    StudioCard {
                        Text("No jobs yet")
                            .font(.headline)
                        Text("Add a download, conversion, trim, or transcription job to see progress here.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(appState.queueStore.jobs) { job in
                            StudioCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(job.request.title)
                                                .font(.headline)
                                            Text(job.request.subtitle)
                                                .foregroundStyle(.secondary)
                                            if job.request.isAutoSubtitleJob {
                                                Text("Linked auto-subtitle job")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }

                                        Spacer()
                                        StatusBadge(status: job.status)
                                    }

                                    ProgressView(value: job.progress)
                                    Text(job.phase)
                                        .font(.subheadline)

                                    if let outputURL = job.outputURL {
                                        Text(outputURL.path)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    HStack {
                                        Button("Show Logs") {
                                            appState.queueStore.selectedJobID = job.id
                                            appState.inspectorMode = .logs
                                        }

                                        if let transcribeURL = appState.transcriptionSourceURL(for: job) {
                                            Button("Transcribe") {
                                                appState.loadMediaIntoTranscribe(transcribeURL)
                                            }
                                        }

                                        if job.status == .running {
                                            Button("Cancel") {
                                                appState.queueStore.cancel(jobID: job.id)
                                            }
                                        }

                                        if job.status == .failed || job.status == .cancelled {
                                            Button("Retry") {
                                                appState.queueStore.retry(jobID: job.id)
                                            }
                                        }

                                        if job.outputURL != nil {
                                            Button("Reveal") {
                                                appState.queueStore.selectedJobID = job.id
                                                appState.revealSelectedOutput()
                                            }
                                        }

                                    }

                                    SubtitleArtifactSection(
                                        artifacts: job.subtitleArtifacts,
                                        onPreview: { artifact in
                                            appState.queueStore.selectedJobID = job.id
                                            appState.previewArtifact(artifact)
                                        },
                                        onOpen: { artifact in
                                            appState.openTranscript(artifact.url)
                                        },
                                        onReveal: { artifact in
                                            FileHelpers.reveal(artifact.url)
                                        }
                                    )

                                    if !job.logs.isEmpty {
                                        DisclosureGroup("Recent log output") {
                                            ForEach(Array(job.logs.suffix(6).enumerated()), id: \.offset) { _, line in
                                                Text(line)
                                                    .font(.system(.caption, design: .monospaced))
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }
                                    }
                                }
                            }
                            .onTapGesture {
                                appState.queueStore.selectedJobID = job.id
                                appState.inspectorArtifactPath = nil
                            }
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.queueList)
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
        }
    }
}

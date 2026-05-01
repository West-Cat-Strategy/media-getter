import SwiftUI

struct QueueWorkspaceView: View {
    @Bindable var appState: AppState

    var body: some View {
        WorkspaceContainer {
            WorkspaceHeader(
                title: "Queue",
                subtitle: "Track active media jobs, inspect logs, and route outputs into the next workflow."
            )

            if appState.queueStore.jobs.isEmpty {
                WorkspaceSection(title: "No jobs yet") {
                    Text("Add a download, conversion, trim, or transcription job to see progress here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(appState.queueStore.jobs) { job in
                        StudioCard {
                            VStack(alignment: .leading, spacing: 12) {
                                ViewThatFits(in: .horizontal) {
                                    HStack(alignment: .top) {
                                        jobSummary(for: job)
                                        Spacer()
                                        StatusBadge(status: job.status)
                                    }

                                    VStack(alignment: .leading, spacing: 10) {
                                        jobSummary(for: job)
                                        StatusBadge(status: job.status)
                                    }
                                }

                                ProgressView(value: job.progress)
                                Text(job.phase)
                                    .font(.subheadline)

                                if let outputURL = job.outputURL {
                                    CompactPathText(path: outputURL.path)
                                }

                                AdaptiveButtonRow {
                                    Button("Show Logs") {
                                        appState.queueStore.selectedJobID = job.id
                                        appState.inspectorMode = .logs
                                    }

                                    if let transcribeURL = appState.transcriptionSourceURL(for: job) {
                                        Button("Transcribe") {
                                            appState.loadMediaIntoTranscribe(transcribeURL)
                                        }
                                    }

                                    if job.status == .pending || job.status == .running || job.status == .cancelling {
                                        Button("Cancel") {
                                            appState.queueStore.cancel(jobID: job.id)
                                        }
                                        .disabled(job.status == .cancelling)
                                        .accessibilityIdentifier(AccessibilityID.queueJobCancelButton)
                                    }

                                    if job.status == .failed || job.status == .cancelled {
                                        Button("Retry") {
                                            appState.queueStore.retry(jobID: job.id)
                                        }
                                        .accessibilityIdentifier(AccessibilityID.queueJobRetryButton)
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
    }

    private func jobSummary(for job: JobRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.request.title)
                .font(.headline)
                .lineLimit(2)
            Text(job.request.subtitle)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if job.request.isAutoSubtitleJob {
                Text("Linked auto-subtitle job")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

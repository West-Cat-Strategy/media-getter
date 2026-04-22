import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct TrimWorkspaceView: View {
    @Bindable var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                WorkspaceHeader(
                    title: "Trim",
                    subtitle: "Preview one local clip, set precise in and out points, and export a short segment with fast copy when it is safe."
                )

                StudioCard {
                    Text("Clip source")
                        .font(.headline)

                    if let inputURL = appState.trimDraft.inputURL {
                        Text(inputURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Open a file to start trimming.")
                            .foregroundStyle(.secondary)
                    }

                    Button("Open Clip") {
                        appState.selectedSection = .trim
                        appState.openMediaFileForCurrentSection()
                    }
                    .buttonStyle(InteractiveButtonStyle())
                    .accessibilityIdentifier(AccessibilityID.trimOpenButton)
                }
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                    DropSupport.handleURLOrTextProviders(
                        providers,
                        onFile: { fileURL in
                            Task { await appState.loadLocalFile(fileURL, for: .trim) }
                        },
                        onText: { _ in }
                    )
                }

                StudioCard {
                    Picker("Trim preset", selection: $appState.trimDraft.selectedPreset) {
                        ForEach(OutputPresetID.trimPresets) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .onChange(of: appState.trimDraft.selectedPreset) { _, _ in
                        appState.refreshTrimPlan()
                    }

                    Toggle("Prefer stream copy when safe", isOn: Binding(
                        get: { appState.trimDraft.allowFastCopy },
                        set: {
                            appState.trimDraft.allowFastCopy = $0
                            appState.refreshTrimPlan()
                        }
                    ))

                    Toggle(
                        "Generate subtitles after export",
                        isOn: Binding(
                            get: { appState.trimDraft.subtitleWorkflow.generatesSubtitles },
                            set: {
                                appState.trimDraft.subtitleWorkflow.sourcePolicy = $0 ? .generateOnly : .off
                            }
                        )
                    )
                    .accessibilityIdentifier(AccessibilityID.trimSubtitleToggle)

                    if appState.trimDraft.subtitleWorkflow.generatesSubtitles {
                        Picker("Generated output", selection: $appState.trimDraft.subtitleWorkflow.outputFormat) {
                            ForEach(TranscriptionOutputFormat.subtitleFormats) { format in
                                Text(format.title).tag(format)
                            }
                        }

                        Toggle(
                            "Burn captions into exported video",
                            isOn: $appState.trimDraft.subtitleWorkflow.burnInVideo
                        )

                        Label(
                            appState.transcriptionRuntimeSummary,
                            systemImage: appState.isTranscriptionReady ? "waveform" : "exclamationmark.triangle"
                        )
                        .font(.subheadline.weight(.semibold))

                        Text(appState.transcriptionRuntimeDetail)
                            .foregroundStyle(.secondary)
                    }

                    PathPickerRow(
                        title: "Destination folder",
                        path: appState.trimDraft.destinationDirectoryPath
                    ) {
                        appState.chooseDestinationFolder(for: .trim)
                    }

                    Text("Strategy: \(appState.trimDraft.currentPlan.strategy.rawValue)")
                        .font(.headline)
                    Text(appState.trimDraft.currentPlan.reason)
                        .foregroundStyle(.secondary)

                    Button("Add Trim Job") {
                        appState.enqueueTrim()
                    }
                    .disabled(
                        appState.trimDraft.inputURL == nil
                            || (appState.trimDraft.subtitleWorkflow.needsLocalRuntime && !appState.isTranscriptionReady)
                    )
                    .buttonStyle(InteractiveButtonStyle())
                    .accessibilityIdentifier(AccessibilityID.trimQueueButton)
                }

                if appState.trimDraft.inputURL != nil {
                    StudioCard {
                        VideoPlayer(player: appState.trimPlayer)
                            .frame(height: 340)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        if let duration = appState.trimDraft.metadata?.duration {
                            VStack(alignment: .leading, spacing: 12) {
                                Slider(
                                    value: Binding(
                                        get: { appState.trimDraft.playerPosition },
                                        set: { appState.seekTrimPlayer(to: $0) }
                                    ),
                                    in: 0...max(duration, 0.1)
                                )

                                HStack {
                                    Text("Playhead \(Formatters.timecode(appState.trimDraft.playerPosition))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Mark In") {
                                        appState.setTrimStartToCurrentPosition()
                                    }
                                    Button("Mark Out") {
                                        appState.setTrimEndToCurrentPosition()
                                    }
                                }
                            }
                        }
                    }

                    StudioCard {
                        Text("Timeline")
                            .font(.headline)

                        if appState.trimDraft.isLoadingThumbnails {
                            ProgressView("Generating timeline thumbnails…")
                        } else {
                            TrimTimelineView(
                                frames: appState.trimDraft.timelineFrames,
                                range: appState.trimDraft.range,
                                duration: appState.trimDraft.metadata?.duration ?? 1
                            )
                        }

                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 12) {
                            GridRow {
                                Text("Start")
                                    .foregroundStyle(.secondary)
                                TextField(
                                    "00:00:00.00",
                                    text: Binding(
                                        get: { Formatters.timecode(appState.trimDraft.range.start) },
                                        set: { appState.updateTrimStart(from: $0) }
                                    )
                                )
                                Button("-0.5s") { appState.nudgeTrimStart(by: -0.5) }
                                Button("+0.5s") { appState.nudgeTrimStart(by: 0.5) }
                            }

                            GridRow {
                                Text("End")
                                    .foregroundStyle(.secondary)
                                TextField(
                                    "00:00:00.00",
                                    text: Binding(
                                        get: { Formatters.timecode(appState.trimDraft.range.end) },
                                        set: { appState.updateTrimEnd(from: $0) }
                                    )
                                )
                                Button("-0.5s") { appState.nudgeTrimEnd(by: -0.5) }
                                Button("+0.5s") { appState.nudgeTrimEnd(by: 0.5) }
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
        }
    }
}

private struct TrimTimelineView: View {
    let frames: [ThumbnailFrame]
    let range: TrimRange
    let duration: TimeInterval

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                HStack(spacing: 6) {
                    ForEach(frames) { frame in
                        Image(nsImage: frame.image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 88)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }

                let width = proxy.size.width
                let selectionStart = max(0, min(range.start / max(duration, 0.1), 1)) * width
                let selectionWidth = max(8, (range.duration / max(duration, 0.1)) * width)

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: selectionWidth, height: 96)
                    .offset(x: selectionStart)
            }
        }
        .frame(height: 96)
    }
}

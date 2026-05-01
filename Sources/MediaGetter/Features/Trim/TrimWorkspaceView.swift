import AVKit
import SwiftUI

struct TrimWorkspaceView: View {
    @Bindable var appState: AppState

    var body: some View {
        WorkspaceContainer {
            WorkspaceHeader(
                title: "Trim",
                subtitle: "Preview one clip, mark the range, and export a short segment."
            )

            WorkspaceSection(title: "Source") {
                if let inputURL = appState.trimDraft.inputURL {
                    CompactPathText(path: inputURL.path)
                } else {
                    Text("Open a file to start trimming.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button("Open Clip") {
                    appState.selectedSection = .trim
                    appState.openMediaFileForCurrentSection()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(AccessibilityID.trimOpenButton)
            }

            WorkspaceSection(title: "Export") {
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
                    VStack(alignment: .leading, spacing: 12) {
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
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 2)
                }

                PathPickerRow(
                    title: "Destination folder",
                    path: appState.trimDraft.destinationDirectoryPath
                ) {
                    appState.chooseDestinationFolder(for: .trim)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Strategy: \(appState.trimDraft.currentPlan.strategy.rawValue)")
                        .font(.subheadline.weight(.semibold))
                    Text(appState.trimDraft.currentPlan.reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button("Add Trim Job") {
                    appState.enqueueTrim()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    appState.trimDraft.inputURL == nil
                        || (appState.trimDraft.subtitleWorkflow.needsLocalRuntime && !appState.isTranscriptionReady)
                )
                .accessibilityIdentifier(AccessibilityID.trimQueueButton)
            }

            if appState.trimDraft.inputURL != nil {
                WorkspaceSection(title: "Preview") {
                    VideoPlayer(player: appState.trimPlayer)
                        .frame(minHeight: 220, idealHeight: 300, maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: LayoutMetrics.cardCornerRadius, style: .continuous))

                    if let duration = appState.trimDraft.metadata?.duration {
                        VStack(alignment: .leading, spacing: 12) {
                            Slider(
                                value: Binding(
                                    get: { appState.trimDraft.playerPosition },
                                    set: { appState.seekTrimPlayer(to: $0) }
                                ),
                                in: 0...max(duration, 0.1)
                            )

                            ViewThatFits(in: .horizontal) {
                                HStack {
                                    playheadLabel
                                    Spacer()
                                    trimMarkButtons
                                }

                                VStack(alignment: .leading, spacing: 10) {
                                    playheadLabel
                                    trimMarkButtons
                                }
                            }
                        }
                    }
                }

                WorkspaceSection(title: "Timeline") {
                    if appState.trimDraft.isLoadingThumbnails {
                        ProgressView("Generating timeline thumbnails...")
                    } else {
                        TrimTimelineView(
                            frames: appState.trimDraft.timelineFrames,
                            range: appState.trimDraft.range,
                            duration: appState.trimDraft.metadata?.duration ?? 1
                        )
                    }

                    trimTimeInputs
                }
            }
        }
    }

    private var playheadLabel: some View {
        Text("Playhead \(Formatters.timecode(appState.trimDraft.playerPosition))")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var trimMarkButtons: some View {
        AdaptiveButtonRow {
            Button("Mark In") {
                appState.setTrimStartToCurrentPosition()
            }
            Button("Mark Out") {
                appState.setTrimEndToCurrentPosition()
            }
        }
    }

    private var trimTimeInputs: some View {
        ViewThatFits(in: .horizontal) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                trimTimeGridRow(title: "Start", text: Binding(
                    get: { Formatters.timecode(appState.trimDraft.range.start) },
                    set: { appState.updateTrimStart(from: $0) }
                ), nudgeBack: { appState.nudgeTrimStart(by: -0.5) }, nudgeForward: { appState.nudgeTrimStart(by: 0.5) })

                trimTimeGridRow(title: "End", text: Binding(
                    get: { Formatters.timecode(appState.trimDraft.range.end) },
                    set: { appState.updateTrimEnd(from: $0) }
                ), nudgeBack: { appState.nudgeTrimEnd(by: -0.5) }, nudgeForward: { appState.nudgeTrimEnd(by: 0.5) })
            }

            VStack(alignment: .leading, spacing: 12) {
                trimTimeStackRow(title: "Start", text: Binding(
                    get: { Formatters.timecode(appState.trimDraft.range.start) },
                    set: { appState.updateTrimStart(from: $0) }
                ), nudgeBack: { appState.nudgeTrimStart(by: -0.5) }, nudgeForward: { appState.nudgeTrimStart(by: 0.5) })

                trimTimeStackRow(title: "End", text: Binding(
                    get: { Formatters.timecode(appState.trimDraft.range.end) },
                    set: { appState.updateTrimEnd(from: $0) }
                ), nudgeBack: { appState.nudgeTrimEnd(by: -0.5) }, nudgeForward: { appState.nudgeTrimEnd(by: 0.5) })
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func trimTimeGridRow(
        title: String,
        text: Binding<String>,
        nudgeBack: @escaping () -> Void,
        nudgeForward: @escaping () -> Void
    ) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            TextField("00:00:00.00", text: text)
                .frame(minWidth: 120)
            Button("-0.5s", action: nudgeBack)
            Button("+0.5s", action: nudgeForward)
        }
    }

    private func trimTimeStackRow(
        title: String,
        text: Binding<String>,
        nudgeBack: @escaping () -> Void,
        nudgeForward: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .foregroundStyle(.secondary)
            TextField("00:00:00.00", text: text)
                .frame(maxWidth: 180)
            AdaptiveButtonRow {
                Button("-0.5s", action: nudgeBack)
                Button("+0.5s", action: nudgeForward)
            }
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
                            .frame(height: 78)
                            .clipShape(RoundedRectangle(cornerRadius: LayoutMetrics.cardCornerRadius, style: .continuous))
                    }
                }

                let width = proxy.size.width
                let selectionStart = max(0, min(range.start / max(duration, 0.1), 1)) * width
                let selectionWidth = max(8, (range.duration / max(duration, 0.1)) * width)

                RoundedRectangle(cornerRadius: LayoutMetrics.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: selectionWidth, height: 86)
                    .offset(x: selectionStart)
            }
        }
        .frame(height: 86)
    }
}

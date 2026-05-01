import SwiftUI

struct DownloadWorkspaceView: View {
    @Bindable var appState: AppState
    @State private var isAuthSheetPresented = false

    private var downloadURLBinding: Binding<String> {
        Binding(
            get: { appState.downloadDraft.urlString },
            set: { appState.updateDownloadURL($0) }
        )
    }

    private var selectedAuthProfileBinding: Binding<UUID?> {
        Binding(
            get: { appState.downloadDraft.selectedAuthProfileID },
            set: { appState.updateSelectedDownloadAuthProfileID($0) }
        )
    }

    var body: some View {
        WorkspaceContainer {
                WorkspaceHeader(
                    title: "Download",
                    subtitle: "Paste a public media URL, inspect the available formats, and add a clean download job to the queue."
                )

                StudioCard {
                    Text("Paste or drop a public media URL")
                        .font(.headline)

                    TextField("https://example.com/video", text: downloadURLBinding)
                        .textFieldStyle(.plain)
                        .studioInputStyle()
                        .accessibilityIdentifier(AccessibilityID.downloadURLField)

                    Picker("Authentication", selection: selectedAuthProfileBinding) {
                        Text("No auth")
                            .tag(UUID?.none)

                        ForEach(appState.authProfileStore.profiles) { profile in
                            Text(profile.name)
                                .tag(Optional(profile.id))
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.downloadAuthPicker)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(appState.downloadAuthSummary())
                            .font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier(AccessibilityID.downloadAuthSummary)
                        Text(appState.downloadAuthDetail())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)

                    AdaptiveButtonRow {
                        Button("Paste URL") {
                            appState.pasteURLFromClipboard()
                        }
                        .buttonStyle(InteractiveButtonStyle())

                        Button(appState.downloadDraft.isProbing ? "Inspecting…" : "Inspect URL") {
                            Task { await appState.probeDownloadURL() }
                        }
                        .disabled(appState.downloadDraft.isProbing)
                        .buttonStyle(InteractiveButtonStyle())
                        .accessibilityIdentifier(AccessibilityID.downloadInspectButton)

                        Button("Show Metadata") {
                            appState.inspectorMode = .metadata
                        }
                        .disabled(appState.downloadDraft.metadata == nil)
                        .buttonStyle(InteractiveButtonStyle())

                        Button("Configure Auth…") {
                            isAuthSheetPresented = true
                        }
                        .buttonStyle(InteractiveButtonStyle())
                        .accessibilityIdentifier(AccessibilityID.downloadConfigureAuthButton)
                    }
                }
                .sheet(isPresented: $isAuthSheetPresented) {
                    DownloadAuthProfileSheet(
                        appState: appState,
                        context: .download,
                        initialProfileID: appState.downloadDraft.selectedAuthProfileID
                    )
                }

                if let inlineStatus = appState.downloadInlineStatus {
                    DownloadInlineStatusCard(appState: appState, status: inlineStatus)
                }

                StudioCard {
                    Text("Starter presets")
                        .font(.headline)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                        ForEach(OutputPresetID.starterPresets) { preset in
                            PresetTile(
                                preset: preset,
                                isSelected: appState.downloadDraft.selectedPreset == preset
                            ) {
                                appState.applyStarterPreset(preset)
                            }
                        }
                    }
                }

                if let metadata = appState.downloadDraft.metadata {
                    MetadataSummaryCard(metadata: metadata)

                    StudioCard {
                        Text("Download options")
                            .font(.headline)

                        Picker("Output preset", selection: $appState.downloadDraft.selectedPreset) {
                            ForEach(OutputPresetID.downloadPresets) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }

                        Picker("Format", selection: $appState.downloadDraft.selectedFormatID) {
                            Text("Automatic (best available)")
                                .tag("bestvideo*+bestaudio/best")

                            ForEach(metadata.formats) { format in
                                Text(format.displayName)
                                    .tag(format.id)
                            }
                        }

                        TextField("Filename template", text: $appState.downloadDraft.filenameTemplate)
                            .textFieldStyle(.plain)
                            .studioInputStyle()

                        PathPickerRow(
                            title: "Destination folder",
                            path: appState.downloadDraft.destinationDirectoryPath
                        ) {
                            appState.chooseDestinationFolder(for: .download)
                        }

                        Button("Add Download Job") {
                            appState.enqueueDownload()
                        }
                        .disabled(
                            appState.downloadDraft.subtitleWorkflow.needsLocalRuntime && !appState.isTranscriptionReady
                                || (appState.downloadDraft.subtitleWorkflow.burnInVideo && appState.downloadDraft.selectedPreset.audioOnly)
                        )
                        .buttonStyle(InteractiveButtonStyle())
                        .accessibilityIdentifier(AccessibilityID.downloadQueueButton)
                    }

                    StudioCard {
                        Text("Subtitles")
                            .font(.headline)

                        Picker("Strategy", selection: $appState.downloadDraft.subtitleWorkflow.sourcePolicy) {
                            ForEach(SubtitleSourcePolicy.allCases) { policy in
                                Text(policy.title).tag(policy)
                            }
                        }
                        .accessibilityIdentifier(AccessibilityID.downloadSubtitlePolicyPicker)

                        Text(appState.downloadDraft.subtitleWorkflow.sourcePolicy.detail)
                            .foregroundStyle(.secondary)

                        if appState.downloadDraft.subtitleWorkflow.showsOutputFormatPicker {
                            Picker("Generated output", selection: $appState.downloadDraft.subtitleWorkflow.outputFormat) {
                                ForEach(TranscriptionOutputFormat.subtitleFormats) { format in
                                    Text(format.title).tag(format)
                                }
                            }
                            .accessibilityIdentifier(AccessibilityID.downloadSubtitleFormatPicker)
                        }

                        if appState.downloadDraft.subtitleWorkflow.isEnabled {
                            Toggle(
                                "Burn captions into exported video",
                                isOn: $appState.downloadDraft.subtitleWorkflow.burnInVideo
                            )
                            .toggleStyle(StudioToggleStyle())

                            if appState.downloadDraft.selectedPreset.audioOnly {
                                Text("Caption burn-in only applies to video presets.")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if appState.downloadDraft.subtitleWorkflow.needsLocalRuntime {
                            Label(
                                appState.transcriptionRuntimeSummary,
                                systemImage: appState.isTranscriptionReady ? "waveform" : "exclamationmark.triangle"
                            )
                            .font(.subheadline.weight(.semibold))

                            Text(appState.transcriptionRuntimeDetail)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
        }
    }
}

private struct DownloadInlineStatusCard: View {
    @Bindable var appState: AppState
    let status: DownloadInlineStatus

    var body: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(status.title)
                    .font(.headline)
                    .accessibilityIdentifier(AccessibilityID.downloadInlineStatusTitle)

                Text(status.message)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.downloadInlineStatusMessage)

                if let progress = status.progress {
                    ProgressView(value: progress)
                        .accessibilityIdentifier(AccessibilityID.downloadInlineProgress)
                } else if status.isIndeterminate {
                    ProgressView()
                        .accessibilityIdentifier(AccessibilityID.downloadInlineProgress)
                }

                AdaptiveButtonRow {
                    if let queueButtonTitle = status.queueButtonTitle {
                        Button(queueButtonTitle) {
                            appState.openQueueFromDownloadStatus()
                        }
                        .accessibilityIdentifier(AccessibilityID.downloadInlineOpenQueueButton)
                    }

                    if let cancellableJobID = status.cancellableJobID {
                        Button("Cancel") {
                            appState.cancelDownloadStatusJob(cancellableJobID)
                        }
                        .accessibilityIdentifier(AccessibilityID.downloadInlineCancelButton)
                    }
                }
            }
        }
    }
}

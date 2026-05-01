import SwiftUI

struct DownloadWorkspaceView: View {
    @Bindable var appState: AppState
    @State private var isAuthSheetPresented = false
    @State private var isSubtitleOptionsExpanded = true

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
                subtitle: "Paste a media URL, inspect it, then add the best output to the queue."
            )

            WorkspaceSection(title: "Source", subtitle: "Paste or drop a public media URL.") {
                TextField("https://example.com/video", text: downloadURLBinding)
                    .textFieldStyle(.roundedBorder)
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

                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.downloadAuthSummary())
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier(AccessibilityID.downloadAuthSummary)
                    Text(appState.downloadAuthDetail())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                AdaptiveButtonRow {
                    Button("Paste URL") {
                        appState.pasteURLFromClipboard()
                    }

                    Button(appState.downloadDraft.isProbing ? "Inspecting..." : "Inspect URL") {
                        Task { await appState.probeDownloadURL() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.downloadDraft.isProbing)
                    .accessibilityIdentifier(AccessibilityID.downloadInspectButton)

                    Button("Show Metadata") {
                        appState.inspectorMode = .metadata
                    }
                    .disabled(appState.downloadDraft.metadata == nil)

                    Button("Configure Auth...") {
                        isAuthSheetPresented = true
                    }
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

            WorkspaceSection(title: "Presets") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 12)], spacing: 12) {
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

                WorkspaceSection(title: "Options") {
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
                        .textFieldStyle(.roundedBorder)

                    PathPickerRow(
                        title: "Destination folder",
                        path: appState.downloadDraft.destinationDirectoryPath
                    ) {
                        appState.chooseDestinationFolder(for: .download)
                    }

                    DisclosureGroup("Subtitles", isExpanded: $isSubtitleOptionsExpanded) {
                        subtitleOptions
                            .padding(.top, 8)
                    }

                    Button("Add Download Job") {
                        appState.enqueueDownload()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        appState.downloadDraft.subtitleWorkflow.needsLocalRuntime && !appState.isTranscriptionReady
                            || (appState.downloadDraft.subtitleWorkflow.burnInVideo && appState.downloadDraft.selectedPreset.audioOnly)
                    )
                    .accessibilityIdentifier(AccessibilityID.downloadQueueButton)
                }
            }
        }
    }

    private var subtitleOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Strategy", selection: $appState.downloadDraft.subtitleWorkflow.sourcePolicy) {
                ForEach(SubtitleSourcePolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .accessibilityIdentifier(AccessibilityID.downloadSubtitlePolicyPicker)

            Text(appState.downloadDraft.subtitleWorkflow.sourcePolicy.detail)
                .font(.subheadline)
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

                if appState.downloadDraft.selectedPreset.audioOnly {
                    Text("Caption burn-in only applies to video presets.")
                        .font(.subheadline)
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
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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

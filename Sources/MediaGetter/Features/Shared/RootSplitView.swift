import SwiftUI

struct RootSplitView: View {
    @Bindable var appState: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: $appState.selectedSection) {
                ForEach(AppSection.allCases) { section in
                    HStack(spacing: 10) {
                        Image(systemName: section.systemImage)
                            .frame(width: 16)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                            Text(section.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .tag(section)
                    .accessibilityIdentifier(accessibilityIdentifier(for: section))
                }
            }
            .listStyle(.sidebar)
        } detail: {
            workspaceView
                .padding(24)
                .toolbar {
                    ToolbarItemGroup {
                        Button("Paste URL", systemImage: "clipboard") {
                            appState.pasteURLFromClipboard()
                        }

                        Button("Open File", systemImage: "folder") {
                            appState.openMediaFileForCurrentSection()
                        }

                        Button("Start", systemImage: "play.fill") {
                            Task { await appState.startPrimaryAction() }
                        }

                        Button("Cancel", systemImage: "xmark") {
                            appState.cancelSelectedJob()
                        }

                        Button("Reveal", systemImage: "folder.badge.gearshape") {
                            appState.revealSelectedOutput()
                        }
                    }

                    ToolbarItem {
                        Button(appState.inspectorMode == nil ? "Show Inspector" : "Hide Inspector", systemImage: "sidebar.right") {
                            appState.inspectorMode = appState.inspectorMode == nil ? .metadata : nil
                        }
                    }
                }
        }
        .inspector(isPresented: inspectorBinding) {
            InspectorPanel(appState: appState)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 380)
        }
        .alert(
            appState.alert?.title ?? "Alert",
            isPresented: Binding(
                get: { appState.alert != nil },
                set: { if !$0 { appState.alert = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                appState.alert = nil
            }
        } message: {
            Text(appState.alert?.message ?? "")
        }
    }

    @ViewBuilder
    private var workspaceView: some View {
        switch appState.selectedSection {
        case .download:
            DownloadWorkspaceView(appState: appState)
        case .convert:
            ConvertWorkspaceView(appState: appState)
        case .trim:
            TrimWorkspaceView(appState: appState)
        case .transcribe:
            TranscribeWorkspaceView(appState: appState)
        case .queue:
            QueueWorkspaceView(appState: appState)
        case .history:
            HistoryWorkspaceView(appState: appState)
        }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { appState.inspectorMode != nil },
            set: { if !$0 { appState.inspectorMode = nil } }
        )
    }

    private func accessibilityIdentifier(for section: AppSection) -> String {
        switch section {
        case .download: AccessibilityID.sidebarDownload
        case .convert: AccessibilityID.sidebarConvert
        case .trim: AccessibilityID.sidebarTrim
        case .transcribe: AccessibilityID.sidebarTranscribe
        case .queue: AccessibilityID.sidebarQueue
        case .history: AccessibilityID.sidebarHistory
        }
    }
}

private struct InspectorPanel: View {
    let appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Inspector", selection: Binding(
                    get: { appState.inspectorMode ?? .metadata },
                    set: { appState.inspectorMode = $0 }
                )) {
                    ForEach(InspectorMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch appState.inspectorMode ?? .metadata {
                case .metadata:
                    if let metadata = appState.currentMetadataForInspector() {
                        MetadataSummaryCard(metadata: metadata)
                    } else {
                        Text("No metadata selected yet.")
                            .foregroundStyle(.secondary)
                    }
                case .preset:
                    if let preset = appState.currentPresetForInspector() {
                        StudioCard {
                            Label(preset.title, systemImage: preset.systemImage)
                                .font(.headline)
                            Text(preset.summary)
                                .foregroundStyle(.secondary)
                            Text("Container: \(preset.defaultExtension.uppercased())")
                            Text("Video codec: \(preset.defaultVideoCodec ?? "Copy or none")")
                            Text("Audio codec: \(preset.defaultAudioCodec ?? "None")")
                        }
                    } else {
                        Text("Pick a workflow to inspect its preset.")
                            .foregroundStyle(.secondary)
                    }
                case .logs:
                    let logs = appState.logsForInspector()
                    if logs.isEmpty {
                        Text("Run or select a job to inspect logs.")
                            .foregroundStyle(.secondary)
                    } else {
                        StudioCard {
                            ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                case .transcript:
                    if let transcript = appState.transcriptPreviewForInspector(),
                       let transcriptPath = appState.transcriptPathForInspector() {
                        TranscriptPreviewCard(
                            title: appState.transcriptTitleForInspector(),
                            transcript: transcript,
                            path: transcriptPath
                        )
                    } else {
                        Text("Select a completed transcription job to preview the transcript.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(18)
        }
    }
}

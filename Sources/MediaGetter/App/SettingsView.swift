import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState
    @Bindable var appUpdateManager: AppUpdateManager
    @State private var isAuthSheetPresented = false

    var body: some View {
        Form {
            Section("Updates") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appUpdateManager.versionDescription)
                        .font(.headline)
                    Text("Updates are delivered from the latest GitHub release feed.")
                        .foregroundStyle(.secondary)
                    if let updatesUnavailableMessage = appUpdateManager.updatesUnavailableMessage {
                        Text(updatesUnavailableMessage)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                Toggle("Automatically check for updates", isOn: $appUpdateManager.automaticallyChecksForUpdates)
                    .disabled(!appUpdateManager.canConfigureAutomaticUpdateChecks)

                Toggle("Download updates in the background", isOn: $appUpdateManager.automaticallyDownloadsUpdates)
                    .disabled(!appUpdateManager.canConfigureAutomaticDownloads)

                VStack(alignment: .leading, spacing: 8) {
                    Text(appUpdateManager.updateStatusTitle)
                        .font(.headline)
                    Text(appUpdateManager.updateStatusDetail)
                        .foregroundStyle(.secondary)

                    if let availableUpdate = appUpdateManager.availableUpdate {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(availableUpdate.versionDescription)
                            if !availableUpdate.compatibilityDescription.isEmpty {
                                Text(availableUpdate.compatibilityDescription)
                                    .foregroundStyle(.secondary)
                            }
                            if let expectedContentLength = availableUpdate.expectedContentLength {
                                Text(Formatters.bytes(expectedContentLength))
                                    .foregroundStyle(.secondary)
                            }
                            if let releaseNotes = availableUpdate.releaseNotes {
                                Text(releaseNotes)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(5)
                            }
                        }
                        .padding(.top, 2)
                    }

                    switch appUpdateManager.updatePhase {
                    case .checking, .installing:
                        ProgressView()
                    case .downloading:
                        if let progress = appUpdateManager.downloadProgress {
                            ProgressView(value: progress)
                        } else {
                            ProgressView()
                        }
                    case .extracting:
                        ProgressView(value: appUpdateManager.extractionProgress)
                    case .idle, .updateAvailable, .readyToInstall, .upToDate, .failed:
                        EmptyView()
                    }

                    if let transferProgressLabel = appUpdateManager.transferProgressLabel {
                        Text(transferProgressLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if appUpdateManager.updatePhase == .extracting {
                        Text(appUpdateManager.extractionProgressLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                AdaptiveButtonRow {
                    Button(appUpdateManager.primaryUpdateActionTitle) {
                        appUpdateManager.performPrimaryUpdateAction()
                    }
                    .disabled(!appUpdateManager.canPerformPrimaryUpdateAction)

                    if appUpdateManager.canCancelUpdateSession {
                        Button("Cancel") {
                            appUpdateManager.cancelUpdateSession()
                        }
                        .accessibilityIdentifier(AccessibilityID.updateCancelButton)
                    }

                    if appUpdateManager.canRetryUpdateSession {
                        Button("Retry") {
                            appUpdateManager.retryUpdateSession()
                        }
                        .accessibilityIdentifier(AccessibilityID.updateRetryButton)
                    }

                    if let dismissPendingUpdateTitle = appUpdateManager.dismissPendingUpdateTitle,
                       appUpdateManager.canDismissPendingUpdate {
                        Button(dismissPendingUpdateTitle) {
                            appUpdateManager.dismissPendingUpdate()
                        }
                    }

                    if appUpdateManager.canSkipPendingUpdate {
                        Button("Skip This Version") {
                            appUpdateManager.skipPendingUpdate()
                        }
                    }
                }
            }

            Section("Defaults") {
                PathPickerRow(
                    title: "Default download folder",
                    path: appState.preferencesStore.defaultDownloadFolderPath
                ) {
                        appState.chooseDefaultDownloadFolder()
                }

                Toggle("Overwrite existing files", isOn: $appState.preferencesStore.overwriteExisting)
                    .accessibilityIdentifier(AccessibilityID.settingsOverwriteToggle)

                TextField("Filename template", text: $appState.preferencesStore.filenameTemplate)

                Picker("Default download preset", selection: $appState.preferencesStore.defaultDownloadPreset) {
                    ForEach(OutputPresetID.downloadPresets) { preset in
                        Text(preset.title).tag(preset)
                    }
                }

                Picker("Default convert preset", selection: $appState.preferencesStore.defaultConvertPreset) {
                    ForEach(OutputPresetID.convertPresets) { preset in
                        Text(preset.title).tag(preset)
                    }
                }

                Picker("Hardware acceleration", selection: $appState.preferencesStore.hardwareAcceleration) {
                    ForEach(HardwareAccelerationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Toggle("Prefer fast trim copy when safe", isOn: $appState.preferencesStore.allowFastTrimCopy)
            }

            Section("Subtitle Defaults") {
                Picker("Download subtitle strategy", selection: $appState.preferencesStore.defaultDownloadSubtitlePolicy) {
                    ForEach(SubtitleSourcePolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }

                Toggle("Generate subtitles after convert exports", isOn: $appState.preferencesStore.defaultConvertAutoSubtitles)
                Toggle("Generate subtitles after trim exports", isOn: $appState.preferencesStore.defaultTrimAutoSubtitles)

                Picker("Generated subtitle output", selection: $appState.preferencesStore.defaultSubtitleOutputFormat) {
                    ForEach(TranscriptionOutputFormat.subtitleFormats) { format in
                        Text(format.title).tag(format)
                    }
                }
            }

            Section("Download Authentication") {
                Picker(
                    "Default auth profile",
                    selection: Binding(
                        get: { appState.authProfileStore.defaultProfileID },
                        set: { appState.setDefaultAuthProfile($0) }
                    )
                ) {
                    Text("None")
                        .tag(UUID?.none)

                    ForEach(appState.authProfileStore.profiles) { profile in
                        Text(profile.name)
                            .tag(Optional(profile.id))
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.authProfileStore.defaultProfile?.name ?? "No default auth profile")
                        .font(.headline)
                    Text(appState.authProfileStore.defaultProfile?.summary ?? "Downloads use public access only unless you choose a profile.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                Button("Configure Auth…") {
                    isAuthSheetPresented = true
                }
            }

            Section("Bundled Toolchain") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.bundledRuntimeSummary)
                        .font(.headline)
                    Text(appState.bundledRuntimeDetail)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                if appState.toolVersions.isEmpty {
                    Text("Tool validation will appear after the app launches from a built bundle.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.toolVersions) { version in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(version.tool.displayName)
                                .font(.headline)
                            Text(version.versionString)
                            if version.architecture.isAppleSiliconReady {
                                Text(version.architecture.title)
                                    .foregroundStyle(.green)
                            } else {
                                Text(version.architecture.title)
                                    .foregroundStyle(.secondary)
                            }
                            if version.isSelfContained {
                                Text(version.linkageStatus.title)
                                    .foregroundStyle(.green)
                            } else {
                                Text(version.linkageStatus.title)
                                    .foregroundStyle(.secondary)
                            }
                            Text(version.sourceDescription)
                                .foregroundStyle(.secondary)
                            Text(version.linkageDetail)
                                .foregroundStyle(.secondary)
                            Text(version.executablePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section("Transcription Runtime") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.transcriptionRuntimeSummary)
                        .font(.headline)
                    Text(appState.transcriptionRuntimeDetail)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                if let whisperTool = appState.toolVersions.first(where: { $0.tool == .whisperCLI }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(whisperTool.tool.displayName)
                            .font(.headline)
                        Text(whisperTool.versionString)
                        Text(whisperTool.executablePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    Text("whisper-cli is not bundled yet.")
                        .foregroundStyle(.secondary)
                }

                ForEach(appState.bundledAssetStatuses) { status in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(status.asset.displayName)
                            .font(.headline)
                        if status.isAvailable {
                            Text("Available")
                                .foregroundStyle(.green)
                        } else {
                            Text("Missing")
                                .foregroundStyle(.secondary)
                        }
                        Text(status.detail)
                            .foregroundStyle(.secondary)
                        Text(status.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Third-Party Notices") {
                Text("Apple Silicon only • macOS 14+")
                    .font(.headline)
                Text("Before shipping a release build, replace the placeholder notice file with the exact upstream license texts for yt-dlp, deno, ffmpeg, x264, LAME, whisper.cpp, and the bundled Whisper model assets.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isAuthSheetPresented) {
            DownloadAuthProfileSheet(
                appState: appState,
                context: .settings,
                initialProfileID: appState.authProfileStore.defaultProfileID
            )
        }
    }
}

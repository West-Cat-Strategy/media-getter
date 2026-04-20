import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState

    var body: some View {
        Form {
            Section("Defaults") {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Default download folder")
                        Text(appState.preferencesStore.defaultDownloadFolderPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    Button("Choose Folder") {
                        appState.chooseDefaultDownloadFolder()
                    }
                }

                Toggle("Overwrite existing files", isOn: $appState.preferencesStore.overwriteExisting)

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
    }
}

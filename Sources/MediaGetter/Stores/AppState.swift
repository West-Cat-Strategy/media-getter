import AVFoundation
import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var preferencesStore: PreferencesStore
    var historyStore: HistoryStore
    var queueStore: QueueStore

    var selectedSection: AppSection = .download
    var inspectorMode: InspectorMode?
    var inspectorArtifactPath: String?
    var downloadDraft: DownloadDraft
    var convertDraft: ConvertDraft
    var transcribeDraft: TranscribeDraft
    var trimDraft: TrimDraft
    var toolVersions: [ToolVersionInfo] = []
    var toolIssues: [String] = []
    var bundledAssetStatuses: [BundledAssetStatus] = []
    var alert: AppAlert?

    @ObservationIgnored
    let trimPlayer = AVPlayer()

    @ObservationIgnored
    private var trimTimeObserver: Any?

    @ObservationIgnored
    private var didBootstrap = false

    @ObservationIgnored
    private let processRunner: ProcessRunner

    @ObservationIgnored
    private let toolchainManager: ToolchainManager

    @ObservationIgnored
    private let downloadProbeService: DownloadProbeService

    @ObservationIgnored
    private let downloadService: DownloadService

    @ObservationIgnored
    private let transcodeService: TranscodeService

    @ObservationIgnored
    private let trimService: TrimService

    @ObservationIgnored
    private let transcriptionService: TranscriptionService

    @ObservationIgnored
    private let thumbnailService: ThumbnailService

    init(
        preferencesStore: PreferencesStore = PreferencesStore(),
        historyStore: HistoryStore = HistoryStore(),
        queueStore: QueueStore = QueueStore(),
        toolchainManager: ToolchainManager = ToolchainManager(),
        processRunner: ProcessRunner = ProcessRunner()
    ) {
        self.preferencesStore = preferencesStore
        self.historyStore = historyStore
        self.queueStore = queueStore
        self.processRunner = processRunner
        self.toolchainManager = toolchainManager
        self.downloadProbeService = DownloadProbeService(toolchainManager: toolchainManager, processRunner: processRunner)
        self.downloadService = DownloadService(toolchainManager: toolchainManager, processRunner: processRunner)
        self.transcodeService = TranscodeService(toolchainManager: toolchainManager, processRunner: processRunner)
        self.trimService = TrimService(toolchainManager: toolchainManager, processRunner: processRunner)
        self.transcriptionService = TranscriptionService(toolchainManager: toolchainManager, processRunner: processRunner)
        self.thumbnailService = ThumbnailService()

        let destinationPath = preferencesStore.defaultDownloadFolderPath
        let defaultSubtitleFormat = preferencesStore.defaultSubtitleOutputFormat
        let defaultDownloadSubtitleWorkflow = SubtitleWorkflowOptions(
            sourcePolicy: preferencesStore.defaultDownloadSubtitlePolicy,
            outputFormat: defaultSubtitleFormat
        )
        let defaultConvertSubtitleWorkflow = preferencesStore.defaultConvertAutoSubtitles
            ? SubtitleWorkflowOptions.generateOnly(format: defaultSubtitleFormat)
            : SubtitleWorkflowOptions.off(format: defaultSubtitleFormat)
        let defaultTrimSubtitleWorkflow = preferencesStore.defaultTrimAutoSubtitles
            ? SubtitleWorkflowOptions.generateOnly(format: defaultSubtitleFormat)
            : SubtitleWorkflowOptions.off(format: defaultSubtitleFormat)
        self.downloadDraft = DownloadDraft(
            selectedPreset: preferencesStore.defaultDownloadPreset,
            destinationDirectoryPath: destinationPath,
            subtitleWorkflow: defaultDownloadSubtitleWorkflow,
            filenameTemplate: preferencesStore.filenameTemplate
        )
        self.convertDraft = ConvertDraft(
            selectedPreset: preferencesStore.defaultConvertPreset,
            destinationDirectoryPath: destinationPath,
            subtitleWorkflow: defaultConvertSubtitleWorkflow
        )
        self.transcribeDraft = TranscribeDraft(
            destinationDirectoryPath: destinationPath,
            outputFormat: defaultSubtitleFormat
        )
        self.trimDraft = TrimDraft(
            destinationDirectoryPath: destinationPath,
            subtitleWorkflow: defaultTrimSubtitleWorkflow,
            allowFastCopy: preferencesStore.allowFastTrimCopy
        )
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        queueStore.onCompleted = { [weak self] job in
            self?.handleCompletedJob(job)
        }

        queueStore.setExecutor { [weak self] request, onEvent in
            guard let self else { throw CancellationError() }
            return try await self.execute(jobRequest: request, onEvent: onEvent)
        }

        seedUITestDataIfNeeded()
        applyUITestLaunchSelectionIfNeeded()
        installTrimTimeObserverIfNeeded()

        let validation = await toolchainManager.validateAll(using: processRunner)
        toolVersions = validation.versions
        toolIssues = validation.issues
        bundledAssetStatuses = validation.assetStatuses

        if !validation.issues.isEmpty {
            alert = AppAlert(
                title: "Bundled tools need attention",
                message: validation.issues.joined(separator: "\n")
            )
        }
    }

    func pasteURLFromClipboard() {
        guard let clipboardValue = PasteboardHelper.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clipboardValue.isEmpty else {
            alert = AppAlert(title: "Clipboard is empty", message: "Copy a video URL first, then try again.")
            return
        }

        selectedSection = .download
        downloadDraft.urlString = clipboardValue
    }

    func probeDownloadURL() async {
        let trimmedURL = downloadDraft.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            alert = AppAlert(title: "Missing URL", message: "Paste a public media URL to inspect available formats.")
            return
        }

        downloadDraft.isProbing = true
        defer { downloadDraft.isProbing = false }

        do {
            let metadata = try await downloadProbeService.probe(urlString: trimmedURL)
            downloadDraft.metadata = metadata
            if let preferredFormat = metadata.formats.first(where: { $0.hasVideo && $0.hasAudio }) ?? metadata.formats.first {
                downloadDraft.selectedFormatID = preferredFormat.id
            }
            inspectorMode = .metadata
        } catch {
            alert = AppAlert(title: "Could not inspect URL", message: error.localizedDescription)
        }
    }

    func startPrimaryAction() async {
        switch selectedSection {
        case .download:
            if downloadDraft.metadata == nil {
                await probeDownloadURL()
            } else {
                enqueueDownload()
            }
        case .convert:
            enqueueConvert()
        case .trim:
            enqueueTrim()
        case .transcribe:
            enqueueTranscribe()
        case .queue, .history:
            break
        }
    }

    func cancelSelectedJob() {
        guard let jobID = queueStore.selectedJobID ?? queueStore.selectedRunningJob?.id else { return }
        queueStore.cancel(jobID: jobID)
    }

    func chooseDestinationFolder(for section: AppSection? = nil) {
        let targetSection = section ?? selectedSection
        let startURL = URL(fileURLWithPath: currentDestinationPath(for: targetSection), isDirectory: true)
        guard let folderURL = FileHelpers.chooseFolder(startingAt: startURL) else { return }

        switch targetSection {
        case .download:
            downloadDraft.destinationDirectoryPath = folderURL.path
        case .convert:
            convertDraft.destinationDirectoryPath = folderURL.path
        case .transcribe:
            transcribeDraft.destinationDirectoryPath = folderURL.path
        case .trim:
            trimDraft.destinationDirectoryPath = folderURL.path
        case .queue, .history:
            preferencesStore.defaultDownloadFolderPath = folderURL.path
        }
    }

    func chooseDefaultDownloadFolder() {
        guard let folderURL = FileHelpers.chooseFolder(startingAt: preferencesStore.defaultDownloadFolderURL) else { return }
        preferencesStore.defaultDownloadFolderPath = folderURL.path
        if downloadDraft.destinationDirectoryPath.isEmpty {
            downloadDraft.destinationDirectoryPath = folderURL.path
        }
        if convertDraft.destinationDirectoryPath.isEmpty {
            convertDraft.destinationDirectoryPath = folderURL.path
        }
        if transcribeDraft.destinationDirectoryPath.isEmpty {
            transcribeDraft.destinationDirectoryPath = folderURL.path
        }
        if trimDraft.destinationDirectoryPath.isEmpty {
            trimDraft.destinationDirectoryPath = folderURL.path
        }
    }

    func openMediaFileForCurrentSection() {
        guard let fileURL = FileHelpers.chooseMediaFile() else { return }
        let targetSection: AppSection
        switch selectedSection {
        case .trim:
            targetSection = .trim
        case .transcribe:
            targetSection = .transcribe
        default:
            targetSection = .convert
        }
        Task {
            await loadLocalFile(fileURL, for: targetSection)
        }
    }

    func loadLocalFile(_ url: URL, for section: AppSection) async {
        do {
            let metadata = try await transcodeService.inspectLocalMedia(at: url)

            switch section {
            case .convert:
                selectedSection = .convert
                convertDraft.inputURL = url
                convertDraft.metadata = metadata
                convertDraft.destinationDirectoryPath = convertDraft.destinationDirectoryPath.isEmpty
                    ? preferencesStore.defaultDownloadFolderPath
                    : convertDraft.destinationDirectoryPath
                inspectorMode = .metadata

            case .trim:
                selectedSection = .trim
                trimDraft.inputURL = url
                trimDraft.metadata = metadata
                trimDraft.destinationDirectoryPath = trimDraft.destinationDirectoryPath.isEmpty
                    ? preferencesStore.defaultDownloadFolderPath
                    : trimDraft.destinationDirectoryPath
                trimDraft.range = TrimRange(start: 0, end: min(metadata.duration ?? 15, 30))
                trimDraft.playerPosition = 0
                refreshTrimPlan()
                installTrimTimeObserverIfNeeded()
                trimPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
                trimPlayer.pause()
                await loadTrimThumbnails()
                inspectorMode = .metadata

            case .transcribe:
                selectedSection = .transcribe
                transcribeDraft.inputURL = url
                transcribeDraft.metadata = metadata
                transcribeDraft.destinationDirectoryPath = transcribeDraft.destinationDirectoryPath.isEmpty
                    ? preferencesStore.defaultDownloadFolderPath
                    : transcribeDraft.destinationDirectoryPath
                inspectorMode = .metadata

            case .download, .queue, .history:
                break
            }
        } catch {
            alert = AppAlert(title: "Could not read media file", message: error.localizedDescription)
        }
    }

    func enqueueDownload() {
        let trimmedURL = downloadDraft.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            alert = AppAlert(title: "Missing URL", message: "Paste a public media URL first.")
            return
        }

        guard validateSubtitleWorkflow(downloadDraft.subtitleWorkflow) else { return }

        let request = DownloadRequest(
            sourceURLString: trimmedURL,
            destinationDirectory: URL(fileURLWithPath: currentDestinationPath(for: .download), isDirectory: true),
            selectedFormatID: downloadDraft.selectedFormatID,
            preset: downloadDraft.selectedPreset,
            subtitleWorkflow: downloadDraft.subtitleWorkflow,
            filenameTemplate: downloadDraft.filenameTemplate.isEmpty ? preferencesStore.filenameTemplate : downloadDraft.filenameTemplate,
            overwriteExisting: preferencesStore.overwriteExisting
        )

        let title = downloadDraft.metadata?.title ?? trimmedURL
        queueStore.enqueue(
            JobRequest(
                kind: .download,
                title: title,
                subtitle: request.preset.title,
                source: .remote(trimmedURL),
                preset: request.preset,
                transcriptionOutputFormat: nil,
                payload: .download(request)
            )
        )
        selectedSection = .queue
        inspectorMode = .logs
    }

    func enqueueConvert() {
        guard let inputURL = convertDraft.inputURL else {
            alert = AppAlert(title: "Missing source file", message: "Open a local media file to convert it.")
            return
        }

        guard validateSubtitleWorkflow(convertDraft.subtitleWorkflow) else { return }

        let request = ConvertRequest(
            inputURL: inputURL,
            destinationDirectory: URL(fileURLWithPath: currentDestinationPath(for: .convert), isDirectory: true),
            preset: convertDraft.selectedPreset,
            subtitleWorkflow: convertDraft.subtitleWorkflow,
            containerOverride: convertDraft.containerOverride,
            videoCodecOverride: convertDraft.videoCodecOverride,
            audioCodecOverride: convertDraft.audioCodecOverride,
            audioBitrateOverride: convertDraft.audioBitrateOverride,
            overwriteExisting: preferencesStore.overwriteExisting,
            hardwareAcceleration: preferencesStore.hardwareAcceleration
        )

        queueStore.enqueue(
            JobRequest(
                kind: .convert,
                title: inputURL.lastPathComponent,
                subtitle: request.preset.title,
                source: .local(inputURL),
                preset: request.preset,
                transcriptionOutputFormat: nil,
                payload: .convert(request)
            )
        )
        selectedSection = .queue
        inspectorMode = .logs
    }

    func enqueueTrim() {
        guard let inputURL = trimDraft.inputURL else {
            alert = AppAlert(title: "Missing clip", message: "Open a local file before creating a trim job.")
            return
        }

        let duration = trimDraft.metadata?.duration ?? 0
        let normalizedRange = trimDraft.range.normalized(maxDuration: max(duration, trimDraft.range.end))
        guard normalizedRange.duration > 0.25 else {
            alert = AppAlert(title: "Trim range too short", message: "Choose a start and end point that are at least a quarter-second apart.")
            return
        }

        guard validateSubtitleWorkflow(trimDraft.subtitleWorkflow) else { return }

        let request = TrimRequest(
            inputURL: inputURL,
            destinationDirectory: URL(fileURLWithPath: currentDestinationPath(for: .trim), isDirectory: true),
            preset: trimDraft.selectedPreset,
            subtitleWorkflow: trimDraft.subtitleWorkflow,
            range: normalizedRange,
            allowFastCopy: trimDraft.allowFastCopy,
            overwriteExisting: preferencesStore.overwriteExisting
        )

        queueStore.enqueue(
            JobRequest(
                kind: .trim,
                title: inputURL.lastPathComponent,
                subtitle: request.preset.title,
                source: .local(inputURL),
                preset: request.preset,
                transcriptionOutputFormat: nil,
                payload: .trim(request)
            )
        )
        selectedSection = .queue
        inspectorMode = .logs
    }

    func enqueueTranscribe() {
        guard let inputURL = transcribeDraft.inputURL else {
            alert = AppAlert(title: "Missing source file", message: "Open a local media file before creating a transcription job.")
            return
        }

        guard isTranscriptionReady else {
            alert = AppAlert(title: "Transcription runtime incomplete", message: transcriptionRuntimeDetail)
            return
        }

        let request = TranscribeRequest(
            inputURL: inputURL,
            destinationDirectory: URL(fileURLWithPath: currentDestinationPath(for: .transcribe), isDirectory: true),
            outputFormat: transcribeDraft.outputFormat,
            overwriteExisting: preferencesStore.overwriteExisting
        )

        queueStore.enqueue(makeTranscribeJobRequest(for: request, title: inputURL.lastPathComponent))
        selectedSection = .queue
        inspectorMode = .logs
    }

    func revealSelectedOutput() {
        if let queueURL = queueStore.selectedJob?.outputURL {
            FileHelpers.reveal(queueURL)
            return
        }

        if let historyURL = selectedHistoryEntry?.outputURL {
            FileHelpers.reveal(historyURL)
        }
    }

    func applyStarterPreset(_ preset: OutputPresetID) {
        switch preset {
        case .mp4Video, .mp3Audio:
            selectedSection = .download
            downloadDraft.selectedPreset = preset
        case .movMaster, .extractAudio:
            selectedSection = .convert
            convertDraft.selectedPreset = preset
        case .trimClip:
            selectedSection = .trim
            trimDraft.selectedPreset = preset
        }
        inspectorMode = .preset
    }

    func loadHistoryEntryIntoWorkspace(_ entry: HistoryEntry) {
        switch entry.jobKind {
        case .download:
            selectedSection = .download
            downloadDraft.urlString = entry.source.remoteURL ?? downloadDraft.urlString
            downloadDraft.selectedPreset = entry.preset ?? downloadDraft.selectedPreset
            Task { await probeDownloadURL() }
        case .convert:
            if let url = entry.outputURL ?? entry.source.localURL {
                Task { await loadLocalFile(url, for: .convert) }
            }
            convertDraft.selectedPreset = entry.preset ?? convertDraft.selectedPreset
        case .trim:
            if let url = entry.outputURL ?? entry.source.localURL {
                Task { await loadLocalFile(url, for: .trim) }
            }
            trimDraft.selectedPreset = entry.preset ?? trimDraft.selectedPreset
        case .transcribe:
            transcribeDraft.outputFormat = entry.transcriptionOutputFormat ?? transcribeDraft.outputFormat
            if let url = entry.source.localURL {
                Task { await loadLocalFile(url, for: .transcribe) }
            } else if entry.outputURL != nil {
                selectedSection = .history
                historyStore.selectedEntryID = entry.id
                if let artifact = entry.primaryArtifact {
                    previewArtifact(artifact)
                }
            }
        }
    }

    func currentMetadataForInspector() -> MediaMetadata? {
        switch selectedSection {
        case .download:
            return downloadDraft.metadata
        case .convert:
            return convertDraft.metadata
        case .trim:
            return trimDraft.metadata
        case .transcribe:
            return transcribeDraft.metadata
        case .queue, .history:
            return nil
        }
    }

    func currentPresetForInspector() -> OutputPresetID? {
        switch selectedSection {
        case .download:
            return downloadDraft.selectedPreset
        case .convert:
            return convertDraft.selectedPreset
        case .trim:
            return trimDraft.selectedPreset
        case .transcribe:
            return nil
        case .queue:
            return queueStore.selectedJob?.request.preset
        case .history:
            return selectedHistoryEntry?.preset
        }
    }

    func logsForInspector() -> [String] {
        queueStore.selectedJob?.logs ?? []
    }

    func transcriptTitleForInspector() -> String {
        currentTranscriptURLForInspector()?.lastPathComponent ?? "Transcript Preview"
    }

    func transcriptPreviewForInspector() -> String? {
        guard let transcriptURL = currentTranscriptURLForInspector() else { return nil }
        return try? String(contentsOf: transcriptURL, encoding: .utf8)
    }

    func transcriptPathForInspector() -> String? {
        currentTranscriptURLForInspector()?.path
    }

    var isTranscriptionReady: Bool {
        hasBundledTool(.whisperCLI) && assetStatus(for: .whisperBaseEnglishModel)?.isAvailable == true
    }

    var isBundledRuntimeReady: Bool {
        BundledTool.allCases.allSatisfy { tool in
            guard let version = toolVersions.first(where: { $0.tool == tool }) else { return false }
            return version.architecture.isAppleSiliconReady && version.isVendored && version.isSelfContained
        }
    }

    var bundledRuntimeSummary: String {
        if isBundledRuntimeReady {
            return "Apple Silicon-first • Self-contained media toolchain"
        }

        if toolVersions.isEmpty {
            return "Bundled media toolchain validating"
        }

        return "Bundled media toolchain needs attention"
    }

    var bundledRuntimeDetail: String {
        if isBundledRuntimeReady {
            return "All bundled tools are arm64-only and free of Homebrew and Python runtime dependencies."
        }

        if !toolIssues.isEmpty {
            return toolIssues.joined(separator: "\n")
        }

        return "Build the app bundle to validate the vendored Apple Silicon toolchain."
    }

    var transcriptionRuntimeSummary: String {
        if isTranscriptionReady, isAppleSilicon, assetStatus(for: .whisperBaseEnglishCoreML)?.isAvailable == true {
            return "Whisper base.en • English • Apple Silicon optimized"
        }

        if isTranscriptionReady {
            return "Whisper base.en • English • Local transcription"
        }

        return "Whisper runtime incomplete"
    }

    var transcriptionRuntimeDetail: String {
        if !hasBundledTool(.whisperCLI) {
            return "Bundle whisper-cli in the app resources to enable transcription."
        }

        if assetStatus(for: .whisperBaseEnglishModel)?.isAvailable != true {
            return "Bundle Models/ggml-base.en.bin to enable English transcription."
        }

        if assetStatus(for: .whisperBaseEnglishCoreML)?.isAvailable != true {
            return "Bundle Models/ggml-base.en-encoder.mlmodelc to keep transcription optimized for Apple Silicon."
        }

        return "Text, SRT, and VTT transcripts will be written locally in your chosen destination folder."
    }

    func openTranscript(_ url: URL?) {
        FileHelpers.open(url)
    }

    func previewArtifact(_ artifact: JobArtifact) {
        inspectorArtifactPath = artifact.path
        inspectorMode = .transcript
    }

    func loadMediaIntoTranscribe(_ url: URL) {
        Task {
            await loadLocalFile(url, for: .transcribe)
        }
    }

    func transcriptionSourceURL(for job: JobRecord) -> URL? {
        guard job.status == .completed, job.request.kind != .transcribe else { return nil }
        return job.outputURL ?? job.request.source.localURL
    }

    func transcriptionSourceURL(for entry: HistoryEntry) -> URL? {
        guard entry.jobKind != .transcribe else { return nil }
        return entry.outputURL ?? entry.source.localURL
    }

    func makeAutoSubtitleJobRequest(for completedJob: JobRecord) -> JobRequest? {
        guard completedJob.status == .completed, completedJob.request.parentJobID == nil else { return nil }
        guard let inputURL = completedJob.outputURL else { return nil }

        let outputFormat: TranscriptionOutputFormat
        switch completedJob.request.payload {
        case .download(let request):
            guard request.subtitleWorkflow.generatesSubtitles else { return nil }
            if request.subtitleWorkflow.requestsSourceSubtitles, !completedJob.subtitleArtifacts.isEmpty {
                return nil
            }
            outputFormat = request.subtitleWorkflow.outputFormat
        case .convert(let request):
            guard request.subtitleWorkflow.generatesSubtitles else { return nil }
            outputFormat = request.subtitleWorkflow.outputFormat
        case .trim(let request):
            guard request.subtitleWorkflow.generatesSubtitles else { return nil }
            outputFormat = request.subtitleWorkflow.outputFormat
        case .transcribe:
            return nil
        }

        let request = TranscribeRequest(
            inputURL: inputURL,
            destinationDirectory: inputURL.deletingLastPathComponent(),
            outputFormat: outputFormat,
            overwriteExisting: preferencesStore.overwriteExisting
        )

        return makeTranscribeJobRequest(
            for: request,
            title: completedJob.request.title,
            workflowID: completedJob.request.workflowID,
            parentJobID: completedJob.id,
            subtitle: "Auto subtitles (\(outputFormat.shortTitle))"
        )
    }

    func updateTrimStart(from string: String) {
        guard let parsed = Formatters.parseTimecode(string) else { return }
        trimDraft.range.start = min(parsed, trimDraft.range.end)
        refreshTrimPlan()
    }

    func updateTrimEnd(from string: String) {
        guard let parsed = Formatters.parseTimecode(string) else { return }
        trimDraft.range.end = max(parsed, trimDraft.range.start)
        refreshTrimPlan()
    }

    func setTrimStartToCurrentPosition() {
        trimDraft.range.start = min(trimDraft.playerPosition, trimDraft.range.end)
        refreshTrimPlan()
    }

    func setTrimEndToCurrentPosition() {
        trimDraft.range.end = max(trimDraft.playerPosition, trimDraft.range.start)
        refreshTrimPlan()
    }

    func nudgeTrimStart(by delta: TimeInterval) {
        trimDraft.range.start = max(0, min(trimDraft.range.start + delta, trimDraft.range.end))
        refreshTrimPlan()
    }

    func nudgeTrimEnd(by delta: TimeInterval) {
        let maxDuration = trimDraft.metadata?.duration ?? trimDraft.range.end + delta
        trimDraft.range.end = min(maxDuration, max(trimDraft.range.start, trimDraft.range.end + delta))
        refreshTrimPlan()
    }

    func seekTrimPlayer(to seconds: TimeInterval) {
        let clampedSeconds = max(0, seconds)
        trimDraft.playerPosition = clampedSeconds
        trimPlayer.seek(to: CMTime(seconds: clampedSeconds, preferredTimescale: 600))
    }

    func refreshTrimPlan() {
        guard let inputURL = trimDraft.inputURL else {
            trimDraft.currentPlan = TrimPlan(strategy: .reencode, reason: "Open a clip to evaluate trim strategy.")
            return
        }

        let request = TrimRequest(
            inputURL: inputURL,
            destinationDirectory: URL(fileURLWithPath: currentDestinationPath(for: .trim), isDirectory: true),
            preset: trimDraft.selectedPreset,
            subtitleWorkflow: trimDraft.subtitleWorkflow,
            range: trimDraft.range,
            allowFastCopy: trimDraft.allowFastCopy,
            overwriteExisting: preferencesStore.overwriteExisting
        )
        trimDraft.currentPlan = trimService.makePlan(request: request, metadata: trimDraft.metadata)
    }

    var selectedHistoryEntry: HistoryEntry? {
        historyStore.selectedEntry
    }

    private func handleCompletedJob(_ job: JobRecord) {
        historyStore.record(job: job)

        guard isTranscriptionReady, let followUpRequest = makeAutoSubtitleJobRequest(for: job) else {
            return
        }

        queueStore.enqueue(followUpRequest)
    }

    private func validateSubtitleWorkflow(_ workflow: SubtitleWorkflowOptions) -> Bool {
        guard workflow.needsLocalRuntime, !isTranscriptionReady else { return true }
        alert = AppAlert(title: "Transcription runtime incomplete", message: transcriptionRuntimeDetail)
        return false
    }

    private func makeTranscribeJobRequest(
        for request: TranscribeRequest,
        title: String,
        workflowID: UUID = UUID(),
        parentJobID: UUID? = nil,
        subtitle: String? = nil
    ) -> JobRequest {
        JobRequest(
            workflowID: workflowID,
            parentJobID: parentJobID,
            kind: .transcribe,
            title: title,
            subtitle: subtitle ?? request.outputFormat.title,
            source: .local(request.inputURL),
            preset: nil,
            transcriptionOutputFormat: request.outputFormat,
            payload: .transcribe(request)
        )
    }

    private func hasBundledTool(_ tool: BundledTool) -> Bool {
        toolVersions.contains(where: { $0.tool == tool })
    }

    private var isAppleSilicon: Bool {
#if arch(arm64)
        true
#else
        false
#endif
    }

    private func assetStatus(for asset: BundledAsset) -> BundledAssetStatus? {
        bundledAssetStatuses.first(where: { $0.asset == asset })
    }

    private func currentTranscriptURLForInspector() -> URL? {
        if let inspectorArtifactPath {
            return URL(fileURLWithPath: inspectorArtifactPath)
        }

        switch selectedSection {
        case .queue:
            guard queueStore.selectedJob?.request.kind == .transcribe else { return nil }
            return queueStore.selectedJob?.outputURL
        case .history:
            guard selectedHistoryEntry?.jobKind == .transcribe else { return nil }
            return selectedHistoryEntry?.outputURL
        case .download, .convert, .trim, .transcribe:
            return nil
        }
    }

    private func currentDestinationPath(for section: AppSection) -> String {
        switch section {
        case .download:
            return downloadDraft.destinationDirectoryPath.isEmpty ? preferencesStore.defaultDownloadFolderPath : downloadDraft.destinationDirectoryPath
        case .convert:
            return convertDraft.destinationDirectoryPath.isEmpty ? preferencesStore.defaultDownloadFolderPath : convertDraft.destinationDirectoryPath
        case .transcribe:
            return transcribeDraft.destinationDirectoryPath.isEmpty ? preferencesStore.defaultDownloadFolderPath : transcribeDraft.destinationDirectoryPath
        case .trim:
            return trimDraft.destinationDirectoryPath.isEmpty ? preferencesStore.defaultDownloadFolderPath : trimDraft.destinationDirectoryPath
        case .queue, .history:
            return preferencesStore.defaultDownloadFolderPath
        }
    }

    private func execute(
        jobRequest: JobRequest,
        onEvent: @escaping @Sendable (JobEvent) async -> Void
    ) async throws -> JobResult {
        switch jobRequest.payload {
        case .download(let request):
            return try await downloadService.execute(request: request, onEvent: onEvent)
        case .convert(let request):
            let metadata = convertDraft.inputURL == request.inputURL ? convertDraft.metadata : nil
            return try await transcodeService.execute(request: request, metadata: metadata, onEvent: onEvent)
        case .trim(let request):
            let metadata = trimDraft.inputURL == request.inputURL ? trimDraft.metadata : nil
            return try await trimService.execute(request: request, metadata: metadata, onEvent: onEvent)
        case .transcribe(let request):
            let metadata = transcribeDraft.inputURL == request.inputURL ? transcribeDraft.metadata : nil
            return try await transcriptionService.execute(request: request, metadata: metadata, onEvent: onEvent)
        }
    }

    private func loadTrimThumbnails() async {
        guard let url = trimDraft.inputURL,
              let duration = trimDraft.metadata?.duration else {
            trimDraft.timelineFrames = []
            return
        }

        trimDraft.isLoadingThumbnails = true
        let frames = await thumbnailService.generateThumbnails(for: url, duration: duration, count: 8)
        trimDraft.timelineFrames = frames
        trimDraft.isLoadingThumbnails = false
    }

    private func installTrimTimeObserverIfNeeded() {
        guard trimTimeObserver == nil else { return }

        trimTimeObserver = trimPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] currentTime in
            guard let self, !currentTime.seconds.isNaN else { return }
            Task { @MainActor in
                self.trimDraft.playerPosition = currentTime.seconds
            }
        }
    }

    private func seedUITestDataIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        let shouldSeedQueueHistory = arguments.contains("-uitest-seed-transcribe")
        let shouldSeedWorkspaces = arguments.contains("-uitest-seed-subtitle-workspaces")
        guard shouldSeedQueueHistory || shouldSeedWorkspaces else { return }

        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaGetterUITests", isDirectory: true)

        try? FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)

        let mediaURL = fixtureRoot.appendingPathComponent("sample-output.mp4")
        let sourceSubtitleURL = fixtureRoot.appendingPathComponent("sample-output.en.vtt")
        let transcriptURL = fixtureRoot.appendingPathComponent("sample-output-transcript.txt")

        if !FileManager.default.fileExists(atPath: mediaURL.path) {
            try? Data("stub media".utf8).write(to: mediaURL, options: .atomic)
        }

        if !FileManager.default.fileExists(atPath: sourceSubtitleURL.path) {
            try? Data("WEBVTT\n\n00:00.000 --> 00:01.000\nHello from source subtitles.".utf8).write(
                to: sourceSubtitleURL,
                options: .atomic
            )
        }

        if !FileManager.default.fileExists(atPath: transcriptURL.path) {
            try? Data("Hello from the bundled transcript preview.".utf8).write(to: transcriptURL, options: .atomic)
        }

        let localMetadata = MediaMetadata(
            source: .local(mediaURL),
            title: mediaURL.lastPathComponent,
            duration: 42,
            container: "mp4",
            videoCodec: "h264",
            audioCodec: "aac",
            width: 1920,
            height: 1080,
            fileSize: 1_024_000
        )
        let downloadMetadata = MediaMetadata(
            source: .remote("https://example.com/video"),
            title: "Seeded Sample",
            duration: 42,
            extractor: "generic",
            container: "mp4",
            videoCodec: "h264",
            audioCodec: "aac",
            width: 1920,
            height: 1080,
            fileSize: 1_024_000,
            formats: [
                DownloadFormatOption(
                    id: "137+140",
                    ext: "mp4",
                    displayName: "1080p • MP4",
                    resolution: "1920x1080",
                    note: nil,
                    sizeBytes: 1_024_000,
                    fps: 30,
                    hasVideo: true,
                    hasAudio: true
                )
            ]
        )

        if shouldSeedWorkspaces {
            downloadDraft.urlString = "https://example.com/video"
            downloadDraft.metadata = downloadMetadata
            downloadDraft.selectedFormatID = "137+140"
            downloadDraft.destinationDirectoryPath = fixtureRoot.path

            convertDraft.inputURL = mediaURL
            convertDraft.metadata = localMetadata
            convertDraft.destinationDirectoryPath = fixtureRoot.path

            trimDraft.inputURL = mediaURL
            trimDraft.metadata = localMetadata
            trimDraft.destinationDirectoryPath = fixtureRoot.path
            trimDraft.range = TrimRange(start: 0, end: 12)
            trimDraft.currentPlan = trimService.makePlan(
                request: TrimRequest(
                    inputURL: mediaURL,
                    destinationDirectory: fixtureRoot,
                    preset: trimDraft.selectedPreset,
                    subtitleWorkflow: trimDraft.subtitleWorkflow,
                    range: trimDraft.range,
                    allowFastCopy: trimDraft.allowFastCopy,
                    overwriteExisting: preferencesStore.overwriteExisting
                ),
                metadata: localMetadata
            )
        }

        guard shouldSeedQueueHistory else { return }

        let workflowID = UUID()

        let mediaRequest = JobRequest(
            workflowID: workflowID,
            kind: .download,
            title: "Seeded Sample",
            subtitle: OutputPresetID.mp4Video.title,
            source: .remote("https://example.com/video"),
            preset: .mp4Video,
            transcriptionOutputFormat: nil,
            payload: .download(
                DownloadRequest(
                    sourceURLString: "https://example.com/video",
                    destinationDirectory: fixtureRoot,
                    selectedFormatID: "best",
                    preset: .mp4Video,
                    subtitleWorkflow: SubtitleWorkflowOptions(
                        sourcePolicy: .preferSourceThenGenerate,
                        outputFormat: .srt
                    ),
                    filenameTemplate: "%(title)s",
                    overwriteExisting: true
                )
            )
        )

        let transcriptRequest = JobRequest(
            workflowID: workflowID,
            parentJobID: mediaRequest.id,
            kind: .transcribe,
            title: "Seeded Sample",
            subtitle: "Auto subtitles (\(TranscriptionOutputFormat.txt.shortTitle))",
            source: .local(mediaURL),
            preset: nil,
            transcriptionOutputFormat: .txt,
            payload: .transcribe(
                TranscribeRequest(
                    inputURL: mediaURL,
                    destinationDirectory: fixtureRoot,
                    outputFormat: .txt,
                    overwriteExisting: true
                )
            )
        )

        let now = Date()
        let mediaJob = JobRecord(
            id: mediaRequest.id,
            request: mediaRequest,
            status: .completed,
            progress: 1,
            phase: mediaURL.lastPathComponent,
            logs: ["Download finished"],
            artifacts: [
                JobArtifact(kind: .media, url: mediaURL, isPrimary: true),
                JobArtifact(kind: .subtitle, url: sourceSubtitleURL, isPrimary: false)
            ],
            createdAt: now,
            startedAt: now,
            completedAt: now,
            errorMessage: nil
        )
        let transcriptJob = JobRecord(
            id: transcriptRequest.id,
            request: transcriptRequest,
            status: .completed,
            progress: 1,
            phase: transcriptURL.lastPathComponent,
            logs: ["Transcription finished"],
            artifacts: [JobArtifact(kind: .transcript, url: transcriptURL, isPrimary: true)],
            createdAt: now,
            startedAt: now,
            completedAt: now,
            errorMessage: nil
        )

        queueStore.jobs = [transcriptJob, mediaJob]
        queueStore.selectedJobID = transcriptJob.id

        historyStore.entries = [
            HistoryEntry(
                id: transcriptJob.id,
                jobKind: .transcribe,
                title: transcriptJob.request.title,
                subtitle: transcriptJob.request.subtitle,
                source: transcriptJob.request.source,
                workflowID: workflowID,
                parentJobID: mediaJob.id,
                artifacts: transcriptJob.artifacts,
                createdAt: now,
                preset: nil,
                transcriptionOutputFormat: .txt,
                summary: transcriptJob.phase
            ),
            HistoryEntry(
                id: mediaJob.id,
                jobKind: .download,
                title: mediaJob.request.title,
                subtitle: mediaJob.request.subtitle,
                source: mediaJob.request.source,
                workflowID: workflowID,
                artifacts: mediaJob.artifacts,
                createdAt: now,
                preset: .mp4Video,
                transcriptionOutputFormat: nil,
                summary: mediaJob.phase
            )
        ]
        historyStore.selectedEntryID = historyStore.entries.first?.id
    }

    private func applyUITestLaunchSelectionIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments

        if arguments.contains("-uitest-open-convert") {
            selectedSection = .convert
        } else if arguments.contains("-uitest-open-trim") {
            selectedSection = .trim
        } else if arguments.contains("-uitest-open-transcribe") {
            selectedSection = .transcribe
        } else if arguments.contains("-uitest-open-queue") {
            selectedSection = .queue
        } else if arguments.contains("-uitest-open-history") {
            selectedSection = .history
        }
    }
}

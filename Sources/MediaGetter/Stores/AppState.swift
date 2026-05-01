import AVFoundation
import AppKit
import CryptoKit
import Foundation
import Observation

private enum PipelineDestinationRelay {
    case primaryMedia
    case artifact(JobArtifactKind)
    case ignore
}

private struct MediaPipelineProgressPlan {
    var exportRange: ClosedRange<Double>
    var subtitleRange: ClosedRange<Double>?
    var burnRange: ClosedRange<Double>?
}

private struct ResolvedSubtitleArtifacts {
    var artifacts: [JobArtifact]
    var canonicalSubtitleArtifact: JobArtifact?
}

private struct DownloadSourceContext: Equatable {
    var normalizedURLString: String?
    var selectedAuthProfileID: UUID?
}

struct DownloadInlineStatus {
    var title: String
    var message: String
    var progress: Double?
    var isIndeterminate: Bool
    var queueButtonTitle: String?
    var cancellableJobID: UUID?
}

private extension ResolvedDownloadAuth {
    var freshnessFingerprint: String {
        let canonicalValue: String

        switch self {
        case .browser(let configuration):
            canonicalValue = [
                "browser",
                configuration.browser.rawValue,
                configuration.profile ?? "",
                configuration.container ?? ""
            ]
            .joined(separator: "|")

        case .cookieFile(let path):
            canonicalValue = "cookieFile|\(path)"

        case .advancedHeaders(let cookieHeader, let userAgent, let headers):
            let headerValue = headers
                .map { "\($0.trimmedName):\($0.trimmedValue)" }
                .joined(separator: "|")
            canonicalValue = [
                "advancedHeaders",
                cookieHeader,
                userAgent ?? "",
                headerValue
            ]
            .joined(separator: "|")
        }

        let digest = SHA256.hash(data: Data(canonicalValue.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
@Observable
final class AppState {
    var preferencesStore: PreferencesStore
    var historyStore: HistoryStore
    var queueStore: QueueStore
    var authProfileStore: AuthProfileStore

    var selectedSection: AppSection = .download
    var inspectorMode: InspectorMode?
    var inspectorArtifactPath: String?
    var downloadDraft: DownloadDraft
    var xMediaDraft: XMediaDraft
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
    private let xMediaService: XMediaService

    @ObservationIgnored
    private let transcodeService: TranscodeService

    @ObservationIgnored
    private let trimService: TrimService

    @ObservationIgnored
    private let transcriptionService: TranscriptionService

    @ObservationIgnored
    private let thumbnailService: ThumbnailService

    @ObservationIgnored
    private var activeDownloadProbeSessionID = UUID()

    init(
        preferencesStore: PreferencesStore = PreferencesStore(),
        historyStore: HistoryStore = HistoryStore(),
        queueStore: QueueStore = QueueStore(),
        authProfileStore: AuthProfileStore = AuthProfileStore(),
        toolchainManager: ToolchainManager = ToolchainManager(),
        processRunner: ProcessRunner = ProcessRunner()
    ) {
        self.preferencesStore = preferencesStore
        self.historyStore = historyStore
        self.queueStore = queueStore
        self.authProfileStore = authProfileStore
        self.processRunner = processRunner
        self.toolchainManager = toolchainManager
        self.downloadProbeService = DownloadProbeService(toolchainManager: toolchainManager, processRunner: processRunner)
        self.downloadService = DownloadService(toolchainManager: toolchainManager, processRunner: processRunner)
        self.xMediaService = XMediaService(toolchainManager: toolchainManager, processRunner: processRunner)
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
            filenameTemplate: preferencesStore.filenameTemplate,
            selectedAuthProfileID: authProfileStore.defaultProfileID
        )
        self.xMediaDraft = XMediaDraft(
            destinationDirectoryPath: destinationPath
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
        updateDownloadURL(clipboardValue)
    }

    func probeDownloadURL() async {
        guard let trimmedURL = normalizedDownloadURLString(downloadDraft.urlString) else {
            alert = AppAlert(title: "Missing URL", message: "Paste a public media URL to inspect available formats.")
            return
        }

        let resolvedAuth: ResolvedDownloadAuth?
        do {
            resolvedAuth = try resolveSelectedDownloadAuthForCurrentDraft()
        } catch {
            return
        }

        invalidateDownloadProbeState()
        let authFingerprint = downloadAuthFingerprint(for: resolvedAuth)
        let probeSessionID = beginDownloadProbeStatus(
            title: "Inspecting URL",
            message: "Checking available formats for the current source."
        )
        defer { finishDownloadProbeStatus(probeSessionID) }

        do {
            let metadata = try await downloadProbeService.probe(urlString: trimmedURL, auth: resolvedAuth)
            guard isCurrentDownloadProbeSession(probeSessionID) else { return }
            applySuccessfulDownloadProbe(
                metadata: metadata,
                resolvedAuth: resolvedAuth,
                probedURLString: trimmedURL,
                authFingerprint: authFingerprint,
                title: "Inspection complete",
                message: "Review the formats below and add the download job when you're ready."
            )
            inspectorMode = .metadata
        } catch {
            guard isCurrentDownloadProbeSession(probeSessionID) else { return }
            clearDownloadProbeStatus()
            alert = AppAlert(title: "Could not inspect URL", message: error.localizedDescription)
        }
    }

    func authProfileDraft(for profileID: UUID?) -> DownloadAuthProfileDraft {
        do {
            return try authProfileStore.makeDraft(for: profileID)
        } catch {
            alert = AppAlert(title: "Could not open auth profile", message: error.localizedDescription)
            return DownloadAuthProfileDraft(markAsDefault: false)
        }
    }

    @discardableResult
    func saveAuthProfile(_ draft: DownloadAuthProfileDraft, selectForDownload: Bool) -> DownloadAuthProfile? {
        do {
            let selectedProfileBeforeSave = downloadDraft.selectedAuthProfileID
            let profile = try authProfileStore.saveProfile(from: draft)
            if selectForDownload {
                updateSelectedDownloadAuthProfileID(profile.id)
                if selectedProfileBeforeSave == profile.id {
                    invalidateDownloadProbeState()
                }
            } else if downloadDraft.selectedAuthProfileID == profile.id {
                invalidateDownloadProbeState()
            }
            return profile
        } catch {
            alert = AppAlert(title: "Could not save auth profile", message: error.localizedDescription)
            return nil
        }
    }

    func deleteAuthProfile(_ profileID: UUID) {
        do {
            try authProfileStore.deleteProfile(id: profileID)
            if downloadDraft.selectedAuthProfileID == profileID {
                updateSelectedDownloadAuthProfileID(nil)
            }
        } catch {
            alert = AppAlert(title: "Could not delete auth profile", message: error.localizedDescription)
        }
    }

    func setDefaultAuthProfile(_ profileID: UUID?) {
        authProfileStore.setDefaultProfile(id: profileID)
        if downloadDraft.selectedAuthProfileID == nil {
            updateSelectedDownloadAuthProfileID(profileID)
        }
    }

    func selectedDownloadAuthProfile() -> DownloadAuthProfile? {
        authProfileStore.profile(for: downloadDraft.selectedAuthProfileID)
    }

    func downloadAuthSummary() -> String {
        guard let profile = selectedDownloadAuthProfile() else {
            return "No auth"
        }

        return profile.name
    }

    func downloadAuthDetail() -> String {
        guard let profile = selectedDownloadAuthProfile() else {
            return "Public media downloads do not send cookies or custom headers."
        }

        return "\(profile.strategyTitle) • \(profile.summary)"
    }

    func updateDownloadURL(_ urlString: String) {
        let previousContext = currentDownloadSourceContext()
        downloadDraft.urlString = urlString
        invalidateDownloadProbeIfNeeded(from: previousContext)
    }

    func updateSelectedDownloadAuthProfileID(_ profileID: UUID?) {
        let previousContext = currentDownloadSourceContext()
        downloadDraft.selectedAuthProfileID = profileID
        invalidateDownloadProbeIfNeeded(from: previousContext)
    }

    var downloadInlineStatus: DownloadInlineStatus? {
        if let job = currentDownloadInlineJob() {
            let title: String
            switch job.status {
            case .pending:
                title = "Download queued"
            case .running:
                title = "Download in progress"
            case .cancelling:
                title = "Download cancelling"
            case .completed:
                title = "Download finished"
            case .failed:
                title = "Download failed"
            case .cancelled:
                title = "Download cancelled"
            }

            return DownloadInlineStatus(
                title: title,
                message: job.phase,
                progress: job.progress,
                isIndeterminate: false,
                queueButtonTitle: "Open Queue",
                cancellableJobID: (job.status == .pending || job.status == .running) ? job.id : nil
            )
        }

        guard let title = downloadDraft.probeStatusTitle,
              let message = downloadDraft.probeStatusMessage else {
            return nil
        }

        return DownloadInlineStatus(
            title: title,
            message: message,
            progress: nil,
            isIndeterminate: downloadDraft.isProbing,
            queueButtonTitle: nil,
            cancellableJobID: nil
        )
    }

    func openQueueFromDownloadStatus() {
        selectedSection = .queue
        inspectorMode = .logs
    }

    func cancelDownloadStatusJob(_ jobID: UUID) {
        queueStore.cancel(jobID: jobID)
    }

    func applySuccessfulDownloadProbe(
        metadata: MediaMetadata,
        resolvedAuth: ResolvedDownloadAuth?,
        probedURLString: String? = nil,
        authFingerprint: String? = nil,
        title: String,
        message: String
    ) {
        downloadDraft.metadata = metadata
        downloadDraft.lastProbedURLString = probedURLString ?? normalizedDownloadURLString(downloadDraft.urlString)
        downloadDraft.lastProbedAuthFingerprint = authFingerprint ?? downloadAuthFingerprint(for: resolvedAuth)
        downloadDraft.probeStatusTitle = title
        downloadDraft.probeStatusMessage = message

        if let preferredFormat = metadata.formats.first(where: { $0.hasVideo && $0.hasAudio }) ?? metadata.formats.first {
            downloadDraft.selectedFormatID = preferredFormat.id
        } else {
            downloadDraft.selectedFormatID = DownloadDraft.automaticFormatID
        }
    }

    func testDownloadAuthProfile(_ draft: DownloadAuthProfileDraft) async {
        guard let trimmedURL = normalizedDownloadURLString(downloadDraft.urlString) else {
            alert = AppAlert(title: "Missing URL", message: "Paste a media URL before testing authentication.")
            return
        }

        let resolvedAuth: ResolvedDownloadAuth
        do {
            resolvedAuth = try authProfileStore.resolvedAuth(for: draft)
        } catch {
            alert = AppAlert(title: "Could not test authentication", message: error.localizedDescription)
            return
        }

        invalidateDownloadProbeState()
        let authFingerprint = downloadAuthFingerprint(for: resolvedAuth)
        let probeSessionID = beginDownloadProbeStatus(
            title: "Testing authentication",
            message: "Checking the current URL with the selected auth settings."
        )
        defer { finishDownloadProbeStatus(probeSessionID) }

        do {
            let metadata = try await downloadProbeService.probe(urlString: trimmedURL, auth: resolvedAuth)
            guard isCurrentDownloadProbeSession(probeSessionID) else { return }
            applySuccessfulDownloadProbe(
                metadata: metadata,
                resolvedAuth: resolvedAuth,
                probedURLString: trimmedURL,
                authFingerprint: authFingerprint,
                title: "Authentication works",
                message: "The current URL inspected successfully with this profile."
            )
            inspectorMode = .metadata
            alert = AppAlert(title: "Authentication works", message: "The current URL inspected successfully with this profile.")
        } catch {
            guard isCurrentDownloadProbeSession(probeSessionID) else { return }
            clearDownloadProbeStatus()
            alert = AppAlert(title: "Could not test authentication", message: error.localizedDescription)
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
        case .xMedia:
            enqueueXMedia()
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
        case .xMedia:
            xMediaDraft.destinationDirectoryPath = folderURL.path
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
        case .xMedia:
            targetSection = .xMedia
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

            case .download, .xMedia, .queue, .history:
                break
            }
        } catch {
            alert = AppAlert(title: "Could not read media file", message: error.localizedDescription)
        }
    }

    func enqueueDownload() {
        guard let trimmedURL = normalizedDownloadURLString(downloadDraft.urlString) else {
            alert = AppAlert(title: "Missing URL", message: "Paste a public media URL first.")
            return
        }

        let resolvedAuth: ResolvedDownloadAuth?
        do {
            resolvedAuth = try resolveSelectedDownloadAuthForCurrentDraft()
        } catch {
            return
        }

        downloadDraft.subtitleWorkflow = sanitizedSubtitleWorkflow(downloadDraft.subtitleWorkflow)
        guard validateSubtitleWorkflow(downloadDraft.subtitleWorkflow, preset: downloadDraft.selectedPreset) else { return }
        guard downloadDraft.metadata != nil else {
            alert = AppAlert(
                title: "Inspect URL first",
                message: "Inspect the current URL to load fresh formats before adding a download job."
            )
            return
        }
        guard hasFreshDownloadMetadata(for: resolvedAuth) else {
            invalidateDownloadProbeState()
            alert = AppAlert(
                title: "Inspect URL again",
                message: "The current URL or authentication settings changed since the last inspection. Inspect it again to refresh available formats."
            )
            return
        }

        let request = DownloadRequest(
            sourceURLString: trimmedURL,
            destinationDirectory: URL(fileURLWithPath: currentDestinationPath(for: .download), isDirectory: true),
            selectedFormatID: downloadDraft.selectedFormatID,
            preset: downloadDraft.selectedPreset,
            subtitleWorkflow: downloadDraft.subtitleWorkflow,
            filenameTemplate: downloadDraft.filenameTemplate.isEmpty ? preferencesStore.filenameTemplate : downloadDraft.filenameTemplate,
            overwriteExisting: preferencesStore.overwriteExisting,
            resolvedAuth: resolvedAuth
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

    func enqueueXMedia() {
        guard let normalizedHandle = normalizedXMediaHandle(from: xMediaDraft.handle) else {
            alert = AppAlert(title: "Missing handle", message: "Enter an X profile handle first.")
            return
        }

        guard isValidXMediaHandle(normalizedHandle) else {
            alert = AppAlert(title: "Invalid handle", message: "Use an X handle with letters, numbers, or underscores only.")
            return
        }

        let cookieFilePath = expandedXMediaCookiePath(xMediaDraft.cookieFilePath)
        guard !cookieFilePath.isEmpty else {
            alert = AppAlert(title: "Missing cookie file", message: "Choose where MediaGetter should write or read the exported X cookie file.")
            return
        }

        xMediaDraft.handle = normalizedHandle
        xMediaDraft.cookieFilePath = cookieFilePath

        let request = XMediaRequest(
            handle: normalizedHandle,
            destinationDirectory: URL(fileURLWithPath: currentDestinationPath(for: .xMedia), isDirectory: true),
            browser: xMediaDraft.browser,
            cookieFilePath: cookieFilePath
        )

        queueStore.enqueue(
            JobRequest(
                kind: .xMedia,
                title: "X: @\(normalizedHandle)",
                subtitle: "Media Download",
                source: .remote("https://x.com/\(normalizedHandle)/media"),
                preset: nil,
                transcriptionOutputFormat: nil,
                payload: .xMedia(request)
            )
        )
        selectedSection = .queue
        inspectorMode = .logs
    }

    private func normalizedXMediaHandle(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed),
           let host = url.host(percentEncoded: false)?.lowercased(),
           isXMediaHost(host) {
            return url.pathComponents.dropFirst().first?.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        }

        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
    }

    private func isXMediaHost(_ host: String) -> Bool {
        host == "x.com"
            || host.hasSuffix(".x.com")
            || host == "twitter.com"
            || host.hasSuffix(".twitter.com")
    }

    private func isValidXMediaHandle(_ handle: String) -> Bool {
        handle.range(of: #"^[A-Za-z0-9_]{1,15}$"#, options: .regularExpression) != nil
    }

    private func expandedXMediaCookiePath(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "~", with: NSHomeDirectory(), options: [.anchored])
    }

    func enqueueDroppedDownloadText(_ text: String) {
        enqueueDroppedDownloadURLs(remoteURLStrings(in: text))
    }

    func enqueueDroppedDownloadURLs(_ urlStrings: [String]) {
        let urls = uniqueRemoteDownloadURLStrings(urlStrings)
        guard !urls.isEmpty else {
            alert = AppAlert(title: "No downloadable URL found", message: "Drop an http or https media URL from your browser.")
            return
        }

        let resolvedAuth: ResolvedDownloadAuth?
        do {
            resolvedAuth = try resolveSelectedDownloadAuthForCurrentDraft()
        } catch {
            return
        }

        downloadDraft.subtitleWorkflow = sanitizedSubtitleWorkflow(downloadDraft.subtitleWorkflow)
        guard validateSubtitleWorkflow(downloadDraft.subtitleWorkflow, preset: downloadDraft.selectedPreset) else { return }

        for urlString in urls {
            let request = DownloadRequest(
                sourceURLString: urlString,
                destinationDirectory: URL(fileURLWithPath: currentDestinationPath(for: .download), isDirectory: true),
                selectedFormatID: DownloadDraft.automaticFormatID,
                preset: downloadDraft.selectedPreset,
                subtitleWorkflow: downloadDraft.subtitleWorkflow,
                filenameTemplate: downloadDraft.filenameTemplate.isEmpty ? preferencesStore.filenameTemplate : downloadDraft.filenameTemplate,
                overwriteExisting: preferencesStore.overwriteExisting,
                resolvedAuth: resolvedAuth
            )

            queueStore.enqueue(
                JobRequest(
                    kind: .download,
                    title: URL(string: urlString)?.host(percentEncoded: false) ?? urlString,
                    subtitle: request.preset.title,
                    source: .remote(urlString),
                    preset: request.preset,
                    transcriptionOutputFormat: nil,
                    payload: .download(request)
                )
            )
        }

        selectedSection = .queue
        inspectorMode = .logs
    }

    func enqueueConvert() {
        guard let inputURL = convertDraft.inputURL else {
            alert = AppAlert(title: "Missing source file", message: "Open a local media file to convert it.")
            return
        }

        convertDraft.subtitleWorkflow = sanitizedSubtitleWorkflow(convertDraft.subtitleWorkflow)
        guard validateSubtitleWorkflow(convertDraft.subtitleWorkflow, preset: convertDraft.selectedPreset) else { return }

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

    func enqueueDroppedFiles(_ urls: [URL]) {
        enqueueDroppedFiles(urls, for: selectedSection)
    }

    func enqueueDroppedFiles(_ urls: [URL], for targetSection: AppSection) {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }

        switch targetSection {
        case .transcribe:
            enqueueDroppedTranscriptionFiles(fileURLs)
        case .trim:
            if let firstFileURL = fileURLs.first {
                Task {
                    await loadLocalFile(firstFileURL, for: .trim)
                }
            }
        case .download, .xMedia, .convert, .queue, .history:
            enqueueDroppedConvertFiles(fileURLs)
        }
    }

    func enqueueDroppedConvertFiles(_ urls: [URL]) {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }

        convertDraft.subtitleWorkflow = sanitizedSubtitleWorkflow(convertDraft.subtitleWorkflow)
        guard validateSubtitleWorkflow(convertDraft.subtitleWorkflow, preset: convertDraft.selectedPreset) else { return }

        for inputURL in fileURLs {
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
        }

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

        trimDraft.subtitleWorkflow = sanitizedSubtitleWorkflow(trimDraft.subtitleWorkflow)
        guard validateSubtitleWorkflow(trimDraft.subtitleWorkflow, preset: trimDraft.selectedPreset) else { return }

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

    func enqueueDroppedTranscriptionFiles(_ urls: [URL]) {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }

        guard isTranscriptionReady else {
            alert = AppAlert(title: "Transcription runtime incomplete", message: transcriptionRuntimeDetail)
            return
        }

        for inputURL in fileURLs {
            let request = TranscribeRequest(
                inputURL: inputURL,
                destinationDirectory: URL(fileURLWithPath: currentDestinationPath(for: .transcribe), isDirectory: true),
                outputFormat: transcribeDraft.outputFormat,
                overwriteExisting: preferencesStore.overwriteExisting
            )

            queueStore.enqueue(makeTranscribeJobRequest(for: request, title: inputURL.lastPathComponent))
        }

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
            updateDownloadURL(entry.source.remoteURL ?? downloadDraft.urlString)
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
        case .xMedia:
            selectedSection = .xMedia
            if let remoteURL = entry.source.remoteURL,
               let handle = normalizedXMediaHandle(from: remoteURL) {
                xMediaDraft.handle = handle
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
        case .xMedia, .queue, .history:
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
        case .xMedia, .transcribe:
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
            return "All bundled tools include Apple Silicon support and stay free of Homebrew and Python runtime dependencies."
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
    }

    func makeAutoSubtitleJobRequest(for job: JobRecord) -> JobRequest? {
        let workflow: SubtitleWorkflowOptions
        let overwriteExisting: Bool

        switch job.request.payload {
        case .download(let request):
            workflow = request.subtitleWorkflow
            overwriteExisting = request.overwriteExisting
        case .convert(let request):
            workflow = request.subtitleWorkflow
            overwriteExisting = request.overwriteExisting
        case .trim(let request):
            workflow = request.subtitleWorkflow
            overwriteExisting = request.overwriteExisting
        case .xMedia, .transcribe:
            return nil
        }

        guard workflow.generatesSubtitles else { return nil }
        guard !job.artifacts.contains(where: \.isSubtitleArtifact) else { return nil }
        guard let mediaArtifact = job.artifacts.first(where: { $0.kind == .media }) else { return nil }

        let followUpRequest = TranscribeRequest(
            inputURL: mediaArtifact.url,
            destinationDirectory: mediaArtifact.url.deletingLastPathComponent(),
            outputFormat: workflow.outputFormat,
            overwriteExisting: overwriteExisting
        )

        return makeTranscribeJobRequest(
            for: followUpRequest,
            title: mediaArtifact.displayName,
            workflowID: job.request.workflowID,
            parentJobID: job.id,
            subtitle: "Auto subtitles (\(workflow.outputFormat.shortTitle))"
        )
    }

    private func sanitizedSubtitleWorkflow(_ workflow: SubtitleWorkflowOptions) -> SubtitleWorkflowOptions {
        var sanitizedWorkflow = workflow
        if sanitizedWorkflow.generatesSubtitles, !sanitizedWorkflow.outputFormat.isSubtitleFormat {
            sanitizedWorkflow.outputFormat = .srt
        }
        return sanitizedWorkflow
    }

    private func validateSubtitleWorkflow(_ workflow: SubtitleWorkflowOptions, preset: OutputPresetID) -> Bool {
        if workflow.burnInVideo {
            guard workflow.isEnabled else {
                alert = AppAlert(
                    title: "Enable subtitles first",
                    message: "Turn on subtitle handling before burning captions into a video export."
                )
                return false
            }

            guard !preset.audioOnly else {
                alert = AppAlert(
                    title: "Burned captions need video",
                    message: "Caption burn-in is only available for video exports."
                )
                return false
            }
        }

        guard workflow.needsLocalRuntime, !isTranscriptionReady else { return true }
        alert = AppAlert(title: "Transcription runtime incomplete", message: transcriptionRuntimeDetail)
        return false
    }

    private func normalizedDownloadURLString(_ urlString: String) -> String? {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedURL.isEmpty ? nil : trimmedURL
    }

    private func remoteURLStrings(in text: String) -> [String] {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .flatMap { $0.components(separatedBy: CharacterSet(charactersIn: "<>\"'")) }
            .compactMap(normalizedDownloadURLString)
    }

    private func uniqueRemoteDownloadURLStrings(_ urlStrings: [String]) -> [String] {
        var seen = Set<String>()
        return urlStrings.compactMap { candidate in
            guard let normalized = normalizedDownloadURLString(candidate),
                  let url = URL(string: normalized),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }

    private func currentDownloadSourceContext() -> DownloadSourceContext {
        DownloadSourceContext(
            normalizedURLString: normalizedDownloadURLString(downloadDraft.urlString),
            selectedAuthProfileID: downloadDraft.selectedAuthProfileID
        )
    }

    private func invalidateDownloadProbeIfNeeded(from previousContext: DownloadSourceContext) {
        guard currentDownloadSourceContext() != previousContext else { return }
        invalidateDownloadProbeState()
    }

    private func invalidateDownloadProbeState() {
        activeDownloadProbeSessionID = UUID()
        downloadDraft.metadata = nil
        downloadDraft.isProbing = false
        downloadDraft.selectedFormatID = DownloadDraft.automaticFormatID
        downloadDraft.lastProbedURLString = nil
        downloadDraft.lastProbedAuthFingerprint = nil
        clearDownloadProbeStatus()
    }

    private func clearDownloadProbeStatus() {
        downloadDraft.probeStatusTitle = nil
        downloadDraft.probeStatusMessage = nil
    }

    private func beginDownloadProbeStatus(title: String, message: String) -> UUID {
        let sessionID = UUID()
        activeDownloadProbeSessionID = sessionID
        downloadDraft.probeStatusTitle = title
        downloadDraft.probeStatusMessage = message
        downloadDraft.isProbing = true
        return sessionID
    }

    private func finishDownloadProbeStatus(_ sessionID: UUID) {
        guard isCurrentDownloadProbeSession(sessionID) else { return }
        downloadDraft.isProbing = false
    }

    private func isCurrentDownloadProbeSession(_ sessionID: UUID) -> Bool {
        activeDownloadProbeSessionID == sessionID
    }

    private func downloadAuthFingerprint(for resolvedAuth: ResolvedDownloadAuth?) -> String? {
        resolvedAuth?.freshnessFingerprint
    }

    private func hasFreshDownloadMetadata(for resolvedAuth: ResolvedDownloadAuth?) -> Bool {
        guard downloadDraft.metadata != nil else { return false }

        return downloadDraft.lastProbedURLString == normalizedDownloadURLString(downloadDraft.urlString)
            && downloadDraft.lastProbedAuthFingerprint == downloadAuthFingerprint(for: resolvedAuth)
    }

    private func currentDownloadInlineJob() -> JobRecord? {
        guard let currentURL = normalizedDownloadURLString(downloadDraft.urlString) else {
            return nil
        }

        let matchesCurrentSource: (JobRecord) -> Bool = { job in
            guard job.request.kind == .download else { return false }
            return self.normalizedDownloadURLString(job.request.source.remoteURL ?? "") == currentURL
        }

        if let runningJob = queueStore.jobs.first(where: { $0.status == .running && matchesCurrentSource($0) }) {
            return runningJob
        }

        return queueStore.jobs.first(where: { $0.status == .pending && matchesCurrentSource($0) })
    }

    private func resolveSelectedDownloadAuthForCurrentDraft() throws -> ResolvedDownloadAuth? {
        guard let selectedAuthProfileID = downloadDraft.selectedAuthProfileID else {
            return nil
        }

        do {
            return try authProfileStore.resolvedAuth(for: selectedAuthProfileID)
        } catch {
            if authProfileStore.defaultProfileID == selectedAuthProfileID {
                authProfileStore.setDefaultProfile(id: nil)
            }
            updateSelectedDownloadAuthProfileID(nil)
            alert = AppAlert(
                title: "Authentication profile unavailable",
                message: "\(error.localizedDescription)\nChoose another profile or continue without auth."
            )
            throw error
        }
    }

    private func mediaPipelineProgressPlan(
        for workflow: SubtitleWorkflowOptions,
        burnCaptions: Bool
    ) -> MediaPipelineProgressPlan {
        guard workflow.needsSubtitleArtifacts else {
            return MediaPipelineProgressPlan(exportRange: 0...1, subtitleRange: nil, burnRange: nil)
        }

        if burnCaptions {
            return MediaPipelineProgressPlan(
                exportRange: 0...0.64,
                subtitleRange: 0.64...0.88,
                burnRange: 0.88...1
            )
        }

        return MediaPipelineProgressPlan(
            exportRange: 0...0.74,
            subtitleRange: 0.74...1,
            burnRange: nil
        )
    }

    private func subrange(
        of range: ClosedRange<Double>,
        from lowerFraction: Double,
        to upperFraction: Double
    ) -> ClosedRange<Double> {
        let width = range.upperBound - range.lowerBound
        let lowerBound = range.lowerBound + width * lowerFraction
        let upperBound = range.lowerBound + width * upperFraction
        return lowerBound...upperBound
    }

    private func relayPipelineEvent(
        _ event: JobEvent,
        progressRange: ClosedRange<Double>,
        destinationRelay: PipelineDestinationRelay,
        onEvent: @escaping @Sendable (JobEvent) async -> Void
    ) async {
        switch event {
        case .stage(let stage):
            await onEvent(.stage(stage))
        case .progress(let progress):
            let clamped = max(0, min(progress, 1))
            let scaled = progressRange.lowerBound + (progressRange.upperBound - progressRange.lowerBound) * clamped
            await onEvent(.progress(scaled))
        case .destination(let url):
            switch destinationRelay {
            case .primaryMedia:
                await onEvent(.destination(url))
            case .artifact(let kind):
                await onEvent(.artifact(JobArtifact(kind: kind, url: url, isPrimary: false)))
            case .ignore:
                break
            }
        case .artifact(let artifact):
            await onEvent(.artifact(artifact))
        case .phase(let phase):
            await onEvent(.phase(phase))
        case .log(let log):
            await onEvent(.log(log))
        }
    }

    private func mergedArtifacts(
        _ artifacts: [JobArtifact],
        adding newArtifacts: [JobArtifact]
    ) -> [JobArtifact] {
        var merged = artifacts
        for artifact in newArtifacts {
            if let existingIndex = merged.firstIndex(where: { $0.path == artifact.path }) {
                merged[existingIndex] = artifact
            } else {
                merged.append(artifact)
            }
        }
        return merged
    }

    private func subtitleMetadataHint(
        for jobRequest: JobRequest,
        fallback: MediaMetadata?
    ) -> MediaMetadata? {
        switch jobRequest.payload {
        case .download:
            return nil
        case .convert:
            return fallback
        case .trim(let request):
            return MediaMetadata(
                source: .local(request.inputURL),
                title: request.inputURL.lastPathComponent,
                duration: request.range.duration,
                thumbnailURL: fallback?.thumbnailURL,
                extractor: fallback?.extractor,
                container: fallback?.container,
                videoCodec: fallback?.videoCodec,
                audioCodec: fallback?.audioCodec,
                width: fallback?.width,
                height: fallback?.height,
                fileSize: fallback?.fileSize,
                formats: []
            )
        case .xMedia, .transcribe:
            return fallback
        }
    }

    private func canonicalizeSubtitleArtifact(
        _ artifact: JobArtifact,
        mediaURL: URL,
        overwriteExisting: Bool,
        progressRange: ClosedRange<Double>,
        onEvent: @escaping @Sendable (JobEvent) async -> Void
    ) async throws -> JobArtifact {
        let canonicalURL = try await transcodeService.normalizeSubtitleToSRT(
            subtitleURL: artifact.url,
            mediaURL: mediaURL,
            overwriteExisting: overwriteExisting
        ) { [weak self] event in
            guard let self else { return }
            await self.relayPipelineEvent(
                event,
                progressRange: progressRange,
                destinationRelay: .ignore,
                onEvent: onEvent
            )
        }

        let canonicalArtifact = JobArtifact(kind: .subtitle, url: canonicalURL, isPrimary: false)
        await onEvent(.artifact(canonicalArtifact))
        return canonicalArtifact
    }

    private func generatePipelineSubtitles(
        workflow: SubtitleWorkflowOptions,
        mediaURL: URL,
        metadata: MediaMetadata?,
        artifacts: [JobArtifact],
        overwriteExisting: Bool,
        progressRange: ClosedRange<Double>,
        onEvent: @escaping @Sendable (JobEvent) async -> Void
    ) async throws -> ResolvedSubtitleArtifacts {
        let requestedFormat = workflow.outputFormat.isSubtitleFormat ? workflow.outputFormat : .srt
        let generatedOutputURL = TranscodeService.subtitleSidecarURL(for: mediaURL, outputFormat: requestedFormat)
        let generationRange = requestedFormat == .srt ? progressRange : subrange(of: progressRange, from: 0, to: 0.82)

        let transcriptionResult = try await transcriptionService.execute(
            inputURL: mediaURL,
            metadata: metadata,
            outputURL: generatedOutputURL,
            outputFormat: requestedFormat,
            overwriteExisting: overwriteExisting
        ) { [weak self] event in
            guard let self else { return }
            await self.relayPipelineEvent(
                event,
                progressRange: generationRange,
                destinationRelay: .artifact(.subtitle),
                onEvent: onEvent
            )
        }

        var updatedArtifacts = mergedArtifacts(
            artifacts,
            adding: transcriptionResult.artifacts.map {
                JobArtifact(kind: .subtitle, url: $0.url, displayName: $0.displayName, isPrimary: false)
            }
        )

        if requestedFormat == .srt, let canonicalArtifact = updatedArtifacts.last(where: { $0.path == generatedOutputURL.path }) {
            return ResolvedSubtitleArtifacts(artifacts: updatedArtifacts, canonicalSubtitleArtifact: canonicalArtifact)
        }

        guard let generatedArtifact = updatedArtifacts.last(where: { $0.path == generatedOutputURL.path }) else {
            return ResolvedSubtitleArtifacts(artifacts: updatedArtifacts, canonicalSubtitleArtifact: nil)
        }

        let canonicalArtifact = try await canonicalizeSubtitleArtifact(
            generatedArtifact,
            mediaURL: mediaURL,
            overwriteExisting: overwriteExisting,
            progressRange: subrange(of: progressRange, from: 0.82, to: 1),
            onEvent: onEvent
        )
        updatedArtifacts = mergedArtifacts(updatedArtifacts, adding: [canonicalArtifact])
        return ResolvedSubtitleArtifacts(artifacts: updatedArtifacts, canonicalSubtitleArtifact: canonicalArtifact)
    }

    private func resolveSubtitleArtifacts(
        for jobRequest: JobRequest,
        mediaURL: URL,
        artifacts: [JobArtifact],
        metadata: MediaMetadata?,
        progressRange: ClosedRange<Double>,
        onEvent: @escaping @Sendable (JobEvent) async -> Void
    ) async throws -> ResolvedSubtitleArtifacts {
        switch jobRequest.payload {
        case .download(let request):
            if request.subtitleWorkflow.requestsSourceSubtitles,
               let sourceArtifact = artifacts.first(where: { $0.kind == .subtitle }) {
                let canonicalArtifact = try await canonicalizeSubtitleArtifact(
                    sourceArtifact,
                    mediaURL: mediaURL,
                    overwriteExisting: request.overwriteExisting,
                    progressRange: progressRange,
                    onEvent: onEvent
                )
                return ResolvedSubtitleArtifacts(
                    artifacts: mergedArtifacts(artifacts, adding: [canonicalArtifact]),
                    canonicalSubtitleArtifact: canonicalArtifact
                )
            }

            guard request.subtitleWorkflow.generatesSubtitles else {
                return ResolvedSubtitleArtifacts(
                    artifacts: artifacts,
                    canonicalSubtitleArtifact: artifacts.first(where: { $0.url.pathExtension.lowercased() == "srt" })
                )
            }

            return try await generatePipelineSubtitles(
                workflow: request.subtitleWorkflow,
                mediaURL: mediaURL,
                metadata: metadata,
                artifacts: artifacts,
                overwriteExisting: request.overwriteExisting,
                progressRange: progressRange,
                onEvent: onEvent
            )

        case .convert(let request):
            guard request.subtitleWorkflow.generatesSubtitles else {
                return ResolvedSubtitleArtifacts(
                    artifacts: artifacts,
                    canonicalSubtitleArtifact: artifacts.first(where: { $0.url.pathExtension.lowercased() == "srt" })
                )
            }

            return try await generatePipelineSubtitles(
                workflow: request.subtitleWorkflow,
                mediaURL: mediaURL,
                metadata: metadata,
                artifacts: artifacts,
                overwriteExisting: request.overwriteExisting,
                progressRange: progressRange,
                onEvent: onEvent
            )

        case .trim(let request):
            guard request.subtitleWorkflow.generatesSubtitles else {
                return ResolvedSubtitleArtifacts(
                    artifacts: artifacts,
                    canonicalSubtitleArtifact: artifacts.first(where: { $0.url.pathExtension.lowercased() == "srt" })
                )
            }

            return try await generatePipelineSubtitles(
                workflow: request.subtitleWorkflow,
                mediaURL: mediaURL,
                metadata: metadata,
                artifacts: artifacts,
                overwriteExisting: request.overwriteExisting,
                progressRange: progressRange,
                onEvent: onEvent
            )

        case .xMedia, .transcribe:
            return ResolvedSubtitleArtifacts(artifacts: artifacts, canonicalSubtitleArtifact: nil)
        }
    }

    private func exportPipelineSummary(
        mediaURL: URL,
        canonicalSubtitleArtifact: JobArtifact?,
        burnedCaptions: Bool
    ) -> String {
        guard let canonicalSubtitleArtifact else {
            return mediaURL.lastPathComponent
        }

        if burnedCaptions {
            return "\(mediaURL.lastPathComponent) • \(canonicalSubtitleArtifact.displayName) saved • captions burned in"
        }

        return "\(mediaURL.lastPathComponent) • \(canonicalSubtitleArtifact.displayName) saved"
    }

    private func executeExportPipeline(
        jobRequest: JobRequest,
        subtitleWorkflow: SubtitleWorkflowOptions,
        preset: OutputPresetID,
        metadata: MediaMetadata?,
        runExport: (@escaping @Sendable (JobEvent) async -> Void) async throws -> JobResult,
        onEvent: @escaping @Sendable (JobEvent) async -> Void
    ) async throws -> JobResult {
        await onEvent(.stage(.preparing))
        await onEvent(.phase("Preparing job"))
        let progressPlan = mediaPipelineProgressPlan(for: subtitleWorkflow, burnCaptions: subtitleWorkflow.burnInVideo)
        var exportResult = try await runExport { [weak self] event in
            guard let self else { return }
            await self.relayPipelineEvent(
                event,
                progressRange: progressPlan.exportRange,
                destinationRelay: .primaryMedia,
                onEvent: onEvent
            )
        }

        guard let mediaURL = exportResult.outputURL else {
            await onEvent(.progress(1))
            return exportResult
        }

        let resolvedArtifacts: ResolvedSubtitleArtifacts
        if let subtitleRange = progressPlan.subtitleRange {
            resolvedArtifacts = try await resolveSubtitleArtifacts(
                for: jobRequest,
                mediaURL: mediaURL,
                artifacts: exportResult.artifacts,
                metadata: subtitleMetadataHint(for: jobRequest, fallback: metadata),
                progressRange: subtitleRange,
                onEvent: onEvent
            )
        } else {
            resolvedArtifacts = ResolvedSubtitleArtifacts(
                artifacts: exportResult.artifacts,
                canonicalSubtitleArtifact: exportResult.preferredSubtitleArtifact
            )
        }
        exportResult.artifacts = resolvedArtifacts.artifacts

        if subtitleWorkflow.burnInVideo {
            guard let canonicalSubtitleArtifact = resolvedArtifacts.canonicalSubtitleArtifact else {
                throw ProcessRunnerError.launchFailed("No subtitle file was available to burn into the exported video.")
            }

            if let burnRange = progressPlan.burnRange {
                _ = try await transcodeService.burnSubtitles(
                    into: mediaURL,
                    subtitleURL: canonicalSubtitleArtifact.url,
                    preset: preset
                ) { [weak self] event in
                    guard let self else { return }
                    await self.relayPipelineEvent(
                        event,
                        progressRange: burnRange,
                        destinationRelay: .ignore,
                        onEvent: onEvent
                    )
                }
            }
        }

        let summary = exportPipelineSummary(
            mediaURL: mediaURL,
            canonicalSubtitleArtifact: resolvedArtifacts.canonicalSubtitleArtifact,
            burnedCaptions: subtitleWorkflow.burnInVideo
        )
        await onEvent(.phase(summary))
        await onEvent(.progress(1))
        return JobResult(artifacts: exportResult.artifacts, summary: summary)
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
        case .download, .xMedia, .convert, .trim, .transcribe:
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
        case .xMedia:
            return xMediaDraft.destinationDirectoryPath.isEmpty ? preferencesStore.defaultDownloadFolderPath : xMediaDraft.destinationDirectoryPath
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
            return try await executeExportPipeline(
                jobRequest: jobRequest,
                subtitleWorkflow: request.subtitleWorkflow,
                preset: request.preset,
                metadata: downloadDraft.metadata,
                runExport: { event in
                    try await downloadService.execute(request: request, onEvent: event)
                },
                onEvent: onEvent
            )
        case .xMedia(let request):
            return try await xMediaService.execute(request: request, onEvent: onEvent)
        case .convert(let request):
            let metadata = convertDraft.inputURL == request.inputURL ? convertDraft.metadata : nil
            return try await executeExportPipeline(
                jobRequest: jobRequest,
                subtitleWorkflow: request.subtitleWorkflow,
                preset: request.preset,
                metadata: metadata,
                runExport: { event in
                    try await transcodeService.execute(request: request, metadata: metadata, onEvent: event)
                },
                onEvent: onEvent
            )
        case .trim(let request):
            let metadata = trimDraft.inputURL == request.inputURL ? trimDraft.metadata : nil
            return try await executeExportPipeline(
                jobRequest: jobRequest,
                subtitleWorkflow: request.subtitleWorkflow,
                preset: request.preset,
                metadata: metadata,
                runExport: { event in
                    try await trimService.execute(request: request, metadata: metadata, onEvent: event)
                },
                onEvent: onEvent
            )
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
        let shouldSeedAuthProfiles = arguments.contains("-uitest-seed-auth-profiles")
        let shouldSeedDownloadProbeProgress = arguments.contains("-uitest-seed-download-probe-progress")
        let shouldSeedRunningDownload = arguments.contains("-uitest-seed-running-download")
        let shouldSeedFailedDownload = arguments.contains("-uitest-seed-failed-download")
        guard shouldSeedQueueHistory
            || shouldSeedWorkspaces
            || shouldSeedAuthProfiles
            || shouldSeedDownloadProbeProgress
            || shouldSeedRunningDownload
            || shouldSeedFailedDownload else { return }

        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaGetterUITests", isDirectory: true)

        try? FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)

        let mediaURL = fixtureRoot.appendingPathComponent("sample-output.mp4")
        let sourceSubtitleURL = fixtureRoot.appendingPathComponent("sample-output.en.vtt")
        let savedSubtitleURL = fixtureRoot.appendingPathComponent("sample-output.srt")

        if !FileManager.default.fileExists(atPath: mediaURL.path) {
            try? Data("stub media".utf8).write(to: mediaURL, options: .atomic)
        }

        if !FileManager.default.fileExists(atPath: sourceSubtitleURL.path) {
            try? Data("WEBVTT\n\n00:00.000 --> 00:01.000\nHello from source subtitles.".utf8).write(
                to: sourceSubtitleURL,
                options: .atomic
            )
        }

        if !FileManager.default.fileExists(atPath: savedSubtitleURL.path) {
            try? Data("1\n00:00:00,000 --> 00:00:01,000\nHello from the saved subtitle sidecar.\n".utf8).write(
                to: savedSubtitleURL,
                options: .atomic
            )
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

        if shouldSeedAuthProfiles {
            if authProfileStore.profiles.isEmpty {
                _ = try? authProfileStore.saveProfile(
                    from: DownloadAuthProfileDraft(
                        name: "Seeded Browser Auth",
                        strategyKind: .browser,
                        browser: .safari,
                        markAsDefault: true
                    )
                )
            }

            downloadDraft.selectedAuthProfileID = authProfileStore.defaultProfileID
        }

        if shouldSeedWorkspaces {
            downloadDraft.urlString = "https://example.com/video"
            downloadDraft.destinationDirectoryPath = fixtureRoot.path
            let seededResolvedAuth = downloadDraft.selectedAuthProfileID.flatMap { try? authProfileStore.resolvedAuth(for: $0) }
            applySuccessfulDownloadProbe(
                metadata: downloadMetadata,
                resolvedAuth: seededResolvedAuth,
                title: "Inspection complete",
                message: "Review the formats below and add the download job when you're ready."
            )

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

        if shouldSeedDownloadProbeProgress {
            downloadDraft.urlString = "https://example.com/video"
            downloadDraft.destinationDirectoryPath = fixtureRoot.path
            downloadDraft.isProbing = true
            downloadDraft.probeStatusTitle = "Inspecting URL"
            downloadDraft.probeStatusMessage = "Checking available formats for the current source."
        }

        if shouldSeedRunningDownload {
            downloadDraft.urlString = "https://example.com/video"
            downloadDraft.destinationDirectoryPath = fixtureRoot.path
            let now = Date()
            let runningRequest = JobRequest(
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
                        selectedFormatID: DownloadDraft.automaticFormatID,
                        preset: .mp4Video,
                        subtitleWorkflow: .off(format: .srt),
                        filenameTemplate: "%(title)s",
                        overwriteExisting: true,
                        resolvedAuth: nil
                    )
                )
            )

            let runningJob = JobRecord(
                id: runningRequest.id,
                request: runningRequest,
                status: .running,
                stage: .downloading,
                progress: 0.42,
                phase: "Downloading 1.2 MiB/s • ETA 00:03",
                logs: ["download:42.0%|1.2 MiB/s|00:03"],
                artifacts: [],
                createdAt: now,
                startedAt: now,
                completedAt: nil,
                errorMessage: nil
            )

            queueStore.jobs = [runningJob]
            queueStore.selectedJobID = runningJob.id
        }

        if shouldSeedFailedDownload {
            downloadDraft.urlString = "https://example.com/video"
            downloadDraft.destinationDirectoryPath = fixtureRoot.path
            let now = Date()
            let failedRequest = JobRequest(
                kind: .download,
                title: "Seeded Failed Sample",
                subtitle: OutputPresetID.mp4Video.title,
                source: .remote("https://example.com/video"),
                preset: .mp4Video,
                transcriptionOutputFormat: nil,
                payload: .download(
                    DownloadRequest(
                        sourceURLString: "https://example.com/video",
                        destinationDirectory: fixtureRoot,
                        selectedFormatID: DownloadDraft.automaticFormatID,
                        preset: .mp4Video,
                        subtitleWorkflow: .off(format: .srt),
                        filenameTemplate: "%(title)s",
                        overwriteExisting: true,
                        resolvedAuth: nil
                    )
                )
            )

            let failedJob = JobRecord(
                id: failedRequest.id,
                request: failedRequest,
                status: .failed,
                stage: .failed,
                progress: 0.35,
                phase: "Failed",
                logs: ["Process exited with code 1"],
                artifacts: [],
                createdAt: now,
                startedAt: now,
                completedAt: now,
                errorMessage: "Process exited with code 1"
            )

            queueStore.jobs = [failedJob]
            queueStore.selectedJobID = failedJob.id
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
                    overwriteExisting: true,
                    resolvedAuth: nil
                )
            )
        )

        let now = Date()
        let mediaJob = JobRecord(
            id: mediaRequest.id,
            request: mediaRequest,
            status: .completed,
            stage: .completed,
            progress: 1,
            phase: "\(mediaURL.lastPathComponent) • \(savedSubtitleURL.lastPathComponent) saved",
            logs: ["Download finished", "Writing .srt subtitles"],
            artifacts: [
                JobArtifact(kind: .media, url: mediaURL, isPrimary: true),
                JobArtifact(kind: .subtitle, url: sourceSubtitleURL, isPrimary: false),
                JobArtifact(kind: .subtitle, url: savedSubtitleURL, isPrimary: false)
            ],
            createdAt: now,
            startedAt: now,
            completedAt: now,
            errorMessage: nil
        )

        queueStore.jobs = [mediaJob]
        queueStore.selectedJobID = mediaJob.id

        historyStore.entries = [
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

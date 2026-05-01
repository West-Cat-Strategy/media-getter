import AppKit
import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case download
    case xMedia
    case convert
    case trim
    case transcribe
    case queue
    case history

    var id: Self { self }

    var title: String {
        switch self {
        case .download: "Download"
        case .xMedia: "X Media"
        case .convert: "Convert"
        case .trim: "Trim"
        case .transcribe: "Transcribe"
        case .queue: "Queue"
        case .history: "History"
        }
    }

    var subtitle: String {
        switch self {
        case .download: "Paste a URL and pull media"
        case .xMedia: "Download media from X profiles"
        case .convert: "Transcode local or downloaded files"
        case .trim: "Preview and cut a single clip"
        case .transcribe: "Transcribe local or downloaded media"
        case .queue: "Track in-flight jobs and logs"
        case .history: "Reopen recent outputs and rerun work"
        }
    }

    var systemImage: String {
        switch self {
        case .download: "arrow.down.circle"
        case .xMedia: "at.circle"
        case .convert: "arrow.triangle.2.circlepath.circle"
        case .trim: "scissors"
        case .transcribe: "text.bubble"
        case .queue: "list.bullet.clipboard"
        case .history: "clock.arrow.circlepath"
        }
    }
}

enum InspectorMode: String, CaseIterable, Identifiable {
    case metadata
    case preset
    case logs
    case transcript

    var id: Self { self }

    var title: String {
        switch self {
        case .metadata: "Metadata"
        case .preset: "Preset"
        case .logs: "Logs"
        case .transcript: "Transcript"
        }
    }
}

enum JobKind: String, Codable {
    case download
    case xMedia
    case convert
    case trim
    case transcribe
}

enum JobStatus: String, Codable {
    case pending
    case running
    case cancelling
    case completed
    case failed
    case cancelled

    var title: String {
        switch self {
        case .cancelling:
            "Cancelling"
        default:
            rawValue.capitalized
        }
    }

    var tint: NSColor {
        switch self {
        case .pending: .secondaryLabelColor
        case .running: .systemBlue
        case .cancelling: .systemOrange
        case .completed: .systemGreen
        case .failed: .systemRed
        case .cancelled: .systemOrange
        }
    }
}

enum JobExecutionStage: String, Codable, Equatable {
    case queued
    case preparing
    case downloading
    case transcoding
    case trimming
    case extractingAudio
    case generatingSubtitles
    case transcribing
    case normalizingSubtitles
    case burningCaptions
    case writingOutput
    case cancelling
    case completed
    case failed
    case cancelled

    var cancelDescription: String {
        switch self {
        case .queued:
            "queued job"
        case .preparing:
            "preparation"
        case .downloading:
            "download"
        case .transcoding:
            "conversion"
        case .trimming:
            "trim"
        case .extractingAudio:
            "audio extraction"
        case .generatingSubtitles:
            "subtitle generation"
        case .transcribing:
            "transcription"
        case .normalizingSubtitles:
            "subtitle normalization"
        case .burningCaptions:
            "caption burn-in"
        case .writingOutput:
            "output write"
        case .cancelling:
            "job"
        case .completed:
            "completed job"
        case .failed:
            "failed job"
        case .cancelled:
            "cancelled job"
        }
    }
}

enum BundledTool: String, CaseIterable, Codable, Identifiable {
    case ytDlp = "yt-dlp"
    case galleryDl = "gallery-dl"
    case ffmpeg
    case ffprobe
    case deno
    case whisperCLI = "whisper-cli"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ytDlp: "yt-dlp"
        case .galleryDl: "gallery-dl"
        case .ffmpeg: "ffmpeg"
        case .ffprobe: "ffprobe"
        case .deno: "deno"
        case .whisperCLI: "whisper-cli"
        }
    }

    var versionArguments: [String] {
        switch self {
        case .ytDlp, .galleryDl:
            ["--version"]
        case .ffmpeg, .ffprobe:
            ["-version"]
        case .deno:
            ["--version"]
        case .whisperCLI:
            ["-h"]
        }
    }

    var requiredAtLaunch: Bool {
        switch self {
        case .ytDlp, .galleryDl, .ffmpeg, .ffprobe, .deno, .whisperCLI:
            true
        }
    }
}

enum ToolBinaryArchitecture: String, Codable, Equatable {
    case arm64
    case x86_64
    case universal
    case script
    case unknown

    var title: String {
        switch self {
        case .arm64:
            "Apple Silicon (arm64)"
        case .x86_64:
            "Intel (x86_64)"
        case .universal:
            "Universal"
        case .script:
            "Script / Non-native"
        case .unknown:
            "Unknown"
        }
    }

    var isAppleSiliconReady: Bool {
        self == .arm64 || self == .universal
    }
}

enum ToolLinkageStatus: String, Codable, Equatable {
    case selfContained
    case externalDependencies
    case notApplicable
    case unknown

    var title: String {
        switch self {
        case .selfContained:
            "Self-contained"
        case .externalDependencies:
            "External dependencies"
        case .notApplicable:
            "Not applicable"
        case .unknown:
            "Unknown"
        }
    }
}

enum BundledAsset: String, CaseIterable, Codable, Identifiable {
    case whisperBaseEnglishModel = "ggml-base.en.bin"
    case whisperBaseEnglishCoreML = "ggml-base.en-encoder.mlmodelc"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperBaseEnglishModel:
            "Whisper base.en model"
        case .whisperBaseEnglishCoreML:
            "Whisper base.en Core ML encoder"
        }
    }

    var isDirectory: Bool {
        switch self {
        case .whisperBaseEnglishModel:
            false
        case .whisperBaseEnglishCoreML:
            true
        }
    }
}

enum PresetPurpose {
    case download
    case convert
    case trim
}

enum HardwareAccelerationMode: String, Codable, CaseIterable, Identifiable {
    case automatic
    case disabled

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .disabled: "Disabled"
        }
    }
}

enum TranscriptionOutputFormat: String, Codable, CaseIterable, Identifiable {
    case txt
    case srt
    case vtt

    static var subtitleFormats: [TranscriptionOutputFormat] {
        [.srt, .vtt]
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .txt: "Plain Text (.txt)"
        case .srt: "Subtitles (.srt)"
        case .vtt: "WebVTT (.vtt)"
        }
    }

    var fileExtension: String {
        rawValue
    }

    var shortTitle: String {
        switch self {
        case .txt: ".txt"
        case .srt: ".srt"
        case .vtt: ".vtt"
        }
    }

    var artifactKind: JobArtifactKind {
        switch self {
        case .txt:
            .transcript
        case .srt, .vtt:
            .subtitle
        }
    }

    var isSubtitleFormat: Bool {
        artifactKind == .subtitle
    }

    var whisperFlag: String {
        switch self {
        case .txt:
            "--output-txt"
        case .srt:
            "--output-srt"
        case .vtt:
            "--output-vtt"
        }
    }
}

enum SubtitleSourcePolicy: String, Codable, CaseIterable, Identifiable {
    case off
    case sourceOnly
    case generateOnly
    case preferSourceThenGenerate

    var id: Self { self }

    var title: String {
        switch self {
        case .off:
            "Off"
        case .sourceOnly:
            "Source subtitles only"
        case .generateOnly:
            "Generate locally only"
        case .preferSourceThenGenerate:
            "Prefer source, generate fallback"
        }
    }

    var detail: String {
        switch self {
        case .off:
            "Skip subtitle work for this export."
        case .sourceOnly:
            "Keep subtitle handling to files provided by the source download."
        case .generateOnly:
            "Create a local English subtitle file after the export finishes."
        case .preferSourceThenGenerate:
            "Use source subtitles when they arrive as files, otherwise generate a local English subtitle file."
        }
    }

    var requestsSourceSubtitles: Bool {
        switch self {
        case .sourceOnly, .preferSourceThenGenerate:
            true
        case .off, .generateOnly:
            false
        }
    }

    var generatesSubtitles: Bool {
        switch self {
        case .generateOnly, .preferSourceThenGenerate:
            true
        case .off, .sourceOnly:
            false
        }
    }
}

struct SubtitleWorkflowOptions: Codable, Equatable {
    var sourcePolicy: SubtitleSourcePolicy
    var outputFormat: TranscriptionOutputFormat
    var burnInVideo: Bool = false

    static func off(format: TranscriptionOutputFormat) -> SubtitleWorkflowOptions {
        SubtitleWorkflowOptions(sourcePolicy: .off, outputFormat: format)
    }

    static func generateOnly(format: TranscriptionOutputFormat) -> SubtitleWorkflowOptions {
        SubtitleWorkflowOptions(sourcePolicy: .generateOnly, outputFormat: format)
    }

    var requestsSourceSubtitles: Bool {
        sourcePolicy.requestsSourceSubtitles
    }

    var generatesSubtitles: Bool {
        sourcePolicy.generatesSubtitles
    }

    var needsLocalRuntime: Bool {
        generatesSubtitles
    }

    var needsSubtitleArtifacts: Bool {
        requestsSourceSubtitles || generatesSubtitles
    }

    var showsOutputFormatPicker: Bool {
        generatesSubtitles
    }

    var isEnabled: Bool {
        sourcePolicy != .off
    }
}

enum JobArtifactKind: String, Codable {
    case media
    case subtitle
    case transcript
}

struct JobArtifact: Codable, Equatable, Identifiable {
    var id: UUID
    var kind: JobArtifactKind
    var path: String
    var displayName: String
    var isPrimary: Bool

    init(
        id: UUID = UUID(),
        kind: JobArtifactKind,
        url: URL,
        displayName: String? = nil,
        isPrimary: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.path = url.path
        self.displayName = displayName ?? url.lastPathComponent
        self.isPrimary = isPrimary
    }

    var url: URL {
        URL(fileURLWithPath: path)
    }

    var isSubtitleArtifact: Bool {
        switch kind {
        case .subtitle, .transcript:
            true
        case .media:
            false
        }
    }
}

enum OutputPresetID: String, Codable, CaseIterable, Identifiable {
    case mp4Video
    case mp3Audio
    case movMaster
    case trimClip
    case extractAudio

    var id: Self { self }

    var title: String {
        switch self {
        case .mp4Video: "MP4 Video"
        case .mp3Audio: "MP3 Audio"
        case .movMaster: "MOV Master"
        case .trimClip: "Trim Clip"
        case .extractAudio: "Extract Audio"
        }
    }

    var summary: String {
        switch self {
        case .mp4Video: "H.264 video with AAC audio in an MP4 container."
        case .mp3Audio: "Audio-only MP3 export for downloaded or local media."
        case .movMaster: "High-quality MOV export for local transcodes."
        case .trimClip: "Clip export tuned for short video trims."
        case .extractAudio: "Pull audio from a local file as MP3."
        }
    }

    var systemImage: String {
        switch self {
        case .mp4Video: "film"
        case .mp3Audio: "music.note"
        case .movMaster: "square.stack.3d.up"
        case .trimClip: "timeline.selection"
        case .extractAudio: "waveform"
        }
    }

    var purpose: PresetPurpose {
        switch self {
        case .mp4Video, .mp3Audio:
            .download
        case .movMaster, .extractAudio:
            .convert
        case .trimClip:
            .trim
        }
    }

    var defaultExtension: String {
        switch self {
        case .mp4Video, .trimClip:
            "mp4"
        case .mp3Audio, .extractAudio:
            "mp3"
        case .movMaster:
            "mov"
        }
    }

    var audioOnly: Bool {
        switch self {
        case .mp3Audio, .extractAudio:
            true
        case .mp4Video, .movMaster, .trimClip:
            false
        }
    }

    var defaultVideoCodec: String? {
        switch self {
        case .mp4Video, .trimClip:
            "libx264"
        case .movMaster:
            "prores_ks"
        case .mp3Audio, .extractAudio:
            nil
        }
    }

    var defaultAudioCodec: String? {
        switch self {
        case .mp4Video, .trimClip:
            "aac"
        case .movMaster:
            "pcm_s16le"
        case .mp3Audio, .extractAudio:
            "libmp3lame"
        }
    }

    var defaultAudioBitrate: String? {
        switch self {
        case .mp3Audio, .extractAudio:
            "192k"
        case .mp4Video, .trimClip:
            "160k"
        case .movMaster:
            nil
        }
    }

    var defaultFilenameSuffix: String {
        switch self {
        case .mp4Video: "video"
        case .mp3Audio: "audio"
        case .movMaster: "master"
        case .trimClip: "clip"
        case .extractAudio: "audio"
        }
    }

    static var starterPresets: [OutputPresetID] {
        [.mp4Video, .mp3Audio, .trimClip, .extractAudio]
    }

    static var downloadPresets: [OutputPresetID] {
        [.mp4Video, .mp3Audio]
    }

    static var convertPresets: [OutputPresetID] {
        [.mp4Video, .movMaster, .extractAudio]
    }

    static var trimPresets: [OutputPresetID] {
        [.trimClip, .movMaster]
    }
}

struct MediaSource: Codable, Equatable, Identifiable {
    let id: UUID
    var remoteURL: String?
    var localFilePath: String?
    var displayName: String

    init(
        id: UUID = UUID(),
        remoteURL: String? = nil,
        localFilePath: String? = nil,
        displayName: String
    ) {
        self.id = id
        self.remoteURL = remoteURL
        self.localFilePath = localFilePath
        self.displayName = displayName
    }

    static func remote(_ urlString: String) -> MediaSource {
        MediaSource(remoteURL: urlString, displayName: urlString)
    }

    static func local(_ url: URL) -> MediaSource {
        MediaSource(localFilePath: url.path, displayName: url.lastPathComponent)
    }

    var localURL: URL? {
        guard let localFilePath else { return nil }
        return URL(fileURLWithPath: localFilePath)
    }
}

struct DownloadFormatOption: Codable, Equatable, Identifiable {
    var id: String
    var ext: String
    var displayName: String
    var resolution: String?
    var note: String?
    var sizeBytes: Int64?
    var fps: Double?
    var hasVideo: Bool
    var hasAudio: Bool
}

struct MediaMetadata: Equatable, Identifiable {
    let id: UUID
    var source: MediaSource
    var title: String
    var duration: TimeInterval?
    var thumbnailURL: URL?
    var extractor: String?
    var container: String?
    var videoCodec: String?
    var audioCodec: String?
    var width: Int?
    var height: Int?
    var fileSize: Int64?
    var formats: [DownloadFormatOption]

    init(
        id: UUID = UUID(),
        source: MediaSource,
        title: String,
        duration: TimeInterval? = nil,
        thumbnailURL: URL? = nil,
        extractor: String? = nil,
        container: String? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        fileSize: Int64? = nil,
        formats: [DownloadFormatOption] = []
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.duration = duration
        self.thumbnailURL = thumbnailURL
        self.extractor = extractor
        self.container = container
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.width = width
        self.height = height
        self.fileSize = fileSize
        self.formats = formats
    }

    var dimensionsDescription: String? {
        guard let width, let height else { return nil }
        return "\(width) x \(height)"
    }
}

struct TrimRange: Codable, Equatable {
    var start: TimeInterval
    var end: TimeInterval

    var duration: TimeInterval {
        max(0, end - start)
    }

    func normalized(maxDuration: TimeInterval) -> TrimRange {
        let clampedStart = max(0, min(start, maxDuration))
        let clampedEnd = max(clampedStart, min(end, maxDuration))
        return TrimRange(start: clampedStart, end: clampedEnd)
    }
}

struct ToolVersionInfo: Codable, Equatable, Identifiable {
    var tool: BundledTool
    var versionString: String
    var executablePath: String
    var architecture: ToolBinaryArchitecture
    var sourceDescription: String
    var linkageStatus: ToolLinkageStatus
    var linkageDetail: String
    var isVendored: Bool
    var isSelfContained: Bool

    var id: String { tool.rawValue }
}

struct BundledAssetStatus: Equatable, Identifiable {
    var asset: BundledAsset
    var isAvailable: Bool
    var path: String
    var detail: String

    var id: String { asset.rawValue }
}

struct DownloadRequest: Equatable {
    var sourceURLString: String
    var destinationDirectory: URL
    var selectedFormatID: String
    var preset: OutputPresetID
    var subtitleWorkflow: SubtitleWorkflowOptions
    var filenameTemplate: String
    var overwriteExisting: Bool
    var resolvedAuth: ResolvedDownloadAuth?
}

struct ConvertRequest: Equatable {
    var inputURL: URL
    var destinationDirectory: URL
    var preset: OutputPresetID
    var subtitleWorkflow: SubtitleWorkflowOptions
    var containerOverride: String?
    var videoCodecOverride: String?
    var audioCodecOverride: String?
    var audioBitrateOverride: String?
    var overwriteExisting: Bool
    var hardwareAcceleration: HardwareAccelerationMode
}

struct TrimRequest: Equatable {
    var inputURL: URL
    var destinationDirectory: URL
    var preset: OutputPresetID
    var subtitleWorkflow: SubtitleWorkflowOptions
    var range: TrimRange
    var allowFastCopy: Bool
    var overwriteExisting: Bool
}

struct TranscribeRequest: Equatable {
    var inputURL: URL
    var destinationDirectory: URL
    var outputFormat: TranscriptionOutputFormat
    var overwriteExisting: Bool
}

enum XBrowser: String, Codable, CaseIterable, Identifiable {
    case chrome
    case firefox
    case brave

    var id: Self { self }
    var title: String { rawValue.capitalized }

    var ytDlpArgument: String {
        switch self {
        case .chrome: "chrome"
        case .firefox: "firefox"
        case .brave: "brave"
        }
    }
}

struct XMediaRequest: Equatable {
    var handle: String
    var destinationDirectory: URL
    var browser: XBrowser
    var cookieFilePath: String
}

enum JobPayload: Equatable {
    case download(DownloadRequest)
    case xMedia(XMediaRequest)
    case convert(ConvertRequest)
    case trim(TrimRequest)
    case transcribe(TranscribeRequest)
}

struct JobRequest: Identifiable, Equatable {
    var id: UUID = UUID()
    var workflowID: UUID = UUID()
    var parentJobID: UUID?
    var kind: JobKind
    var title: String
    var subtitle: String
    var source: MediaSource
    var preset: OutputPresetID?
    var transcriptionOutputFormat: TranscriptionOutputFormat?
    var payload: JobPayload

    var isAutoSubtitleJob: Bool {
        kind == .transcribe && parentJobID != nil
    }
}

struct JobRecord: Identifiable, Equatable {
    var id: UUID
    var request: JobRequest
    var status: JobStatus
    var stage: JobExecutionStage
    var progress: Double
    var phase: String
    var logs: [String]
    var artifacts: [JobArtifact]
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var errorMessage: String?

    init(
        id: UUID,
        request: JobRequest,
        status: JobStatus,
        stage: JobExecutionStage = .queued,
        progress: Double,
        phase: String,
        logs: [String],
        outputURL: URL? = nil,
        artifacts: [JobArtifact] = [],
        createdAt: Date,
        startedAt: Date?,
        completedAt: Date?,
        errorMessage: String?
    ) {
        self.id = id
        self.request = request
        self.status = status
        self.stage = stage
        self.progress = progress
        self.phase = phase
        self.logs = logs
        self.artifacts = Self.resolvedArtifacts(outputURL: outputURL, artifacts: artifacts, request: request)
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
    }

    var outputURL: URL? {
        primaryArtifact?.url
    }

    var primaryArtifact: JobArtifact? {
        artifacts.first(where: \.isPrimary) ?? artifacts.first
    }

    var subtitleArtifacts: [JobArtifact] {
        artifacts.filter(\.isSubtitleArtifact)
    }

    var preferredSubtitleArtifact: JobArtifact? {
        subtitleArtifacts.first(where: { $0.url.pathExtension.lowercased() == "srt" }) ?? subtitleArtifacts.first
    }

    private static func resolvedArtifacts(outputURL: URL?, artifacts: [JobArtifact], request: JobRequest) -> [JobArtifact] {
        guard artifacts.isEmpty, let outputURL else { return artifacts }
        return [
            JobArtifact(
                kind: defaultArtifactKind(for: request),
                url: outputURL,
                isPrimary: true
            )
        ]
    }

    private static func defaultArtifactKind(for request: JobRequest) -> JobArtifactKind {
        if request.kind == .transcribe, let format = request.transcriptionOutputFormat {
            return format.artifactKind
        }

        return .media
    }
}

struct HistoryEntry: Codable, Equatable, Identifiable {
    var id: UUID
    var jobKind: JobKind
    var title: String
    var subtitle: String
    var source: MediaSource
    var workflowID: UUID?
    var parentJobID: UUID?
    var artifacts: [JobArtifact]
    var createdAt: Date
    var preset: OutputPresetID?
    var transcriptionOutputFormat: TranscriptionOutputFormat?
    var summary: String

    init(
        id: UUID,
        jobKind: JobKind,
        title: String,
        subtitle: String,
        source: MediaSource,
        workflowID: UUID? = nil,
        parentJobID: UUID? = nil,
        outputPath: String? = nil,
        artifacts: [JobArtifact] = [],
        createdAt: Date,
        preset: OutputPresetID?,
        transcriptionOutputFormat: TranscriptionOutputFormat?,
        summary: String
    ) {
        self.id = id
        self.jobKind = jobKind
        self.title = title
        self.subtitle = subtitle
        self.source = source
        self.workflowID = workflowID
        self.parentJobID = parentJobID
        self.artifacts = Self.resolvedArtifacts(
            jobKind: jobKind,
            outputPath: outputPath,
            artifacts: artifacts,
            transcriptionOutputFormat: transcriptionOutputFormat
        )
        self.createdAt = createdAt
        self.preset = preset
        self.transcriptionOutputFormat = transcriptionOutputFormat
        self.summary = summary
    }

    var outputPath: String? {
        outputURL?.path
    }

    var outputURL: URL? {
        primaryArtifact?.url
    }

    var primaryArtifact: JobArtifact? {
        artifacts.first(where: \.isPrimary) ?? artifacts.first
    }

    var subtitleArtifacts: [JobArtifact] {
        artifacts.filter(\.isSubtitleArtifact)
    }

    var preferredSubtitleArtifact: JobArtifact? {
        subtitleArtifacts.first(where: { $0.url.pathExtension.lowercased() == "srt" }) ?? subtitleArtifacts.first
    }

    var isAutoSubtitleJob: Bool {
        jobKind == .transcribe && parentJobID != nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        jobKind = try container.decode(JobKind.self, forKey: .jobKind)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decode(String.self, forKey: .subtitle)
        source = try container.decode(MediaSource.self, forKey: .source)
        workflowID = try container.decodeIfPresent(UUID.self, forKey: .workflowID)
        parentJobID = try container.decodeIfPresent(UUID.self, forKey: .parentJobID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        preset = try container.decodeIfPresent(OutputPresetID.self, forKey: .preset)
        transcriptionOutputFormat = try container.decodeIfPresent(TranscriptionOutputFormat.self, forKey: .transcriptionOutputFormat)
        summary = try container.decode(String.self, forKey: .summary)

        if let artifacts = try container.decodeIfPresent([JobArtifact].self, forKey: .artifacts) {
            self.artifacts = artifacts
        } else {
            let outputPath = try legacyContainer.decodeIfPresent(String.self, forKey: .outputPath)
            self.artifacts = Self.resolvedArtifacts(
                jobKind: jobKind,
                outputPath: outputPath,
                artifacts: [],
                transcriptionOutputFormat: transcriptionOutputFormat
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(jobKind, forKey: .jobKind)
        try container.encode(title, forKey: .title)
        try container.encode(subtitle, forKey: .subtitle)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(workflowID, forKey: .workflowID)
        try container.encodeIfPresent(parentJobID, forKey: .parentJobID)
        try container.encode(artifacts, forKey: .artifacts)
        try container.encodeIfPresent(outputPath, forKey: .outputPath)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(preset, forKey: .preset)
        try container.encodeIfPresent(transcriptionOutputFormat, forKey: .transcriptionOutputFormat)
        try container.encode(summary, forKey: .summary)
    }

    private static func resolvedArtifacts(
        jobKind: JobKind,
        outputPath: String?,
        artifacts: [JobArtifact],
        transcriptionOutputFormat: TranscriptionOutputFormat?
    ) -> [JobArtifact] {
        guard artifacts.isEmpty, let outputPath else { return artifacts }
        let url = URL(fileURLWithPath: outputPath)
        let kind: JobArtifactKind
        if jobKind == .transcribe {
            kind = transcriptionOutputFormat?.artifactKind ?? .transcript
        } else {
            kind = .media
        }

        return [JobArtifact(kind: kind, url: url, isPrimary: true)]
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case jobKind
        case title
        case subtitle
        case source
        case workflowID
        case parentJobID
        case artifacts
        case outputPath
        case createdAt
        case preset
        case transcriptionOutputFormat
        case summary
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case outputPath
    }
}

struct AppAlert: Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var message: String
}

struct ThumbnailFrame: Identifiable {
    var id: UUID = UUID()
    var time: TimeInterval
    var image: NSImage
}

struct TrimPlan: Equatable {
    enum Strategy: String, Equatable {
        case streamCopy
        case reencode
    }

    var strategy: Strategy
    var reason: String
}

enum JobEvent: Equatable {
    case stage(JobExecutionStage)
    case phase(String)
    case progress(Double)
    case log(String)
    case destination(URL)
    case artifact(JobArtifact)
}

struct JobResult: Equatable {
    var artifacts: [JobArtifact]
    var summary: String

    init(outputURL: URL?, summary: String, artifactKind: JobArtifactKind = .media) {
        if let outputURL {
            self.artifacts = [JobArtifact(kind: artifactKind, url: outputURL, isPrimary: true)]
        } else {
            self.artifacts = []
        }
        self.summary = summary
    }

    init(artifacts: [JobArtifact], summary: String) {
        self.artifacts = artifacts
        self.summary = summary
    }

    var outputURL: URL? {
        artifacts.first(where: \.isPrimary)?.url ?? artifacts.first?.url
    }

    var primaryArtifact: JobArtifact? {
        artifacts.first(where: \.isPrimary) ?? artifacts.first
    }

    var subtitleArtifacts: [JobArtifact] {
        artifacts.filter(\.isSubtitleArtifact)
    }

    var preferredSubtitleArtifact: JobArtifact? {
        subtitleArtifacts.first(where: { $0.url.pathExtension.lowercased() == "srt" }) ?? subtitleArtifacts.first
    }
}

struct DownloadDraft: Equatable {
    static let automaticFormatID = "bestvideo*+bestaudio/best"

    var urlString: String = ""
    var selectedPreset: OutputPresetID = .mp4Video
    var selectedFormatID: String = automaticFormatID
    var destinationDirectoryPath: String = ""
    var subtitleWorkflow: SubtitleWorkflowOptions = .off(format: .srt)
    var filenameTemplate: String = "%(title)s"
    var selectedAuthProfileID: UUID?
    var metadata: MediaMetadata?
    var isProbing: Bool = false
    var lastProbedURLString: String?
    var lastProbedAuthFingerprint: String?
    var probeStatusTitle: String?
    var probeStatusMessage: String?
}

struct ConvertDraft: Equatable {
    var inputURL: URL?
    var metadata: MediaMetadata?
    var selectedPreset: OutputPresetID = .mp4Video
    var destinationDirectoryPath: String = ""
    var subtitleWorkflow: SubtitleWorkflowOptions = .off(format: .srt)
    var containerOverride: String = ""
    var videoCodecOverride: String = ""
    var audioCodecOverride: String = ""
    var audioBitrateOverride: String = ""
    var showAdvanced: Bool = false
}

struct TranscribeDraft: Equatable {
    var inputURL: URL?
    var metadata: MediaMetadata?
    var destinationDirectoryPath: String = ""
    var outputFormat: TranscriptionOutputFormat = .srt
}

struct TrimDraft {
    var inputURL: URL?
    var metadata: MediaMetadata?
    var selectedPreset: OutputPresetID = .trimClip
    var destinationDirectoryPath: String = ""
    var subtitleWorkflow: SubtitleWorkflowOptions = .off(format: .srt)
    var range: TrimRange = .init(start: 0, end: 15)
    var allowFastCopy: Bool = true
    var timelineFrames: [ThumbnailFrame] = []
    var playerPosition: TimeInterval = 0
    var isLoadingThumbnails: Bool = false
    var currentPlan: TrimPlan = .init(strategy: .reencode, reason: "Open a clip to evaluate trim strategy.")
}

struct XMediaDraft: Equatable {
    var handle: String = ""
    var destinationDirectoryPath: String = ""
    var browser: XBrowser = .chrome
    var cookieFilePath: String = (NSHomeDirectory() as NSString).appendingPathComponent("twitter-cookies.txt")
}

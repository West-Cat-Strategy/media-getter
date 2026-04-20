import AppKit
import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case download
    case convert
    case trim
    case transcribe
    case queue
    case history

    var id: Self { self }

    var title: String {
        switch self {
        case .download: "Download"
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
    case convert
    case trim
    case transcribe
}

enum JobStatus: String, Codable {
    case pending
    case running
    case completed
    case failed
    case cancelled

    var title: String {
        rawValue.capitalized
    }

    var tint: NSColor {
        switch self {
        case .pending: .secondaryLabelColor
        case .running: .systemBlue
        case .completed: .systemGreen
        case .failed: .systemRed
        case .cancelled: .systemOrange
        }
    }
}

enum BundledTool: String, CaseIterable, Codable, Identifiable {
    case ytDlp = "yt-dlp"
    case ffmpeg
    case ffprobe
    case deno
    case whisperCLI = "whisper-cli"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ytDlp: "yt-dlp"
        case .ffmpeg: "ffmpeg"
        case .ffprobe: "ffprobe"
        case .deno: "deno"
        case .whisperCLI: "whisper-cli"
        }
    }

    var versionArguments: [String] {
        switch self {
        case .ytDlp:
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
        case .ytDlp, .ffmpeg, .ffprobe, .deno, .whisperCLI:
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
        self == .arm64
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
    var includeSubtitles: Bool
    var filenameTemplate: String
    var overwriteExisting: Bool
}

struct ConvertRequest: Equatable {
    var inputURL: URL
    var destinationDirectory: URL
    var preset: OutputPresetID
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

enum JobPayload: Equatable {
    case download(DownloadRequest)
    case convert(ConvertRequest)
    case trim(TrimRequest)
    case transcribe(TranscribeRequest)
}

struct JobRequest: Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: JobKind
    var title: String
    var subtitle: String
    var source: MediaSource
    var preset: OutputPresetID?
    var transcriptionOutputFormat: TranscriptionOutputFormat?
    var payload: JobPayload
}

struct JobRecord: Identifiable, Equatable {
    var id: UUID
    var request: JobRequest
    var status: JobStatus
    var progress: Double
    var phase: String
    var logs: [String]
    var outputURL: URL?
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var errorMessage: String?
}

struct HistoryEntry: Codable, Equatable, Identifiable {
    var id: UUID
    var jobKind: JobKind
    var title: String
    var subtitle: String
    var source: MediaSource
    var outputPath: String?
    var createdAt: Date
    var preset: OutputPresetID?
    var transcriptionOutputFormat: TranscriptionOutputFormat?
    var summary: String

    var outputURL: URL? {
        guard let outputPath else { return nil }
        return URL(fileURLWithPath: outputPath)
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
    case phase(String)
    case progress(Double)
    case log(String)
    case destination(URL)
}

struct JobResult: Equatable {
    var outputURL: URL?
    var summary: String
}

struct DownloadDraft: Equatable {
    var urlString: String = ""
    var selectedPreset: OutputPresetID = .mp4Video
    var selectedFormatID: String = "bestvideo*+bestaudio/best"
    var destinationDirectoryPath: String = ""
    var includeSubtitles: Bool = false
    var filenameTemplate: String = "%(title)s"
    var metadata: MediaMetadata?
    var isProbing: Bool = false
}

struct ConvertDraft: Equatable {
    var inputURL: URL?
    var metadata: MediaMetadata?
    var selectedPreset: OutputPresetID = .mp4Video
    var destinationDirectoryPath: String = ""
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
    var outputFormat: TranscriptionOutputFormat = .txt
}

struct TrimDraft {
    var inputURL: URL?
    var metadata: MediaMetadata?
    var selectedPreset: OutputPresetID = .trimClip
    var destinationDirectoryPath: String = ""
    var range: TrimRange = .init(start: 0, end: 15)
    var allowFastCopy: Bool = true
    var timelineFrames: [ThumbnailFrame] = []
    var playerPosition: TimeInterval = 0
    var isLoadingThumbnails: Bool = false
    var currentPlan: TrimPlan = .init(strategy: .reencode, reason: "Open a clip to evaluate trim strategy.")
}

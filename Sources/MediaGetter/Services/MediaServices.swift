import AVFoundation
import AppKit
import Foundation

private struct YTDLPProbeResponse: Decodable {
    struct Format: Decodable {
        var format_id: String
        var ext: String?
        var format_note: String?
        var resolution: String?
        var filesize: Int64?
        var fps: Double?
        var vcodec: String?
        var acodec: String?
    }

    var title: String?
    var duration: Double?
    var thumbnail: String?
    var extractor: String?
    var webpage_url: String?
    var formats: [Format]?
}

private struct FFprobeResponse: Decodable {
    struct Stream: Decodable {
        var codec_type: String?
        var codec_name: String?
        var width: Int?
        var height: Int?
    }

    struct Format: Decodable {
        var format_name: String?
        var duration: String?
        var size: String?
    }

    var streams: [Stream]
    var format: Format
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var firstPercentageValue: Double? {
        guard let percentRange = range(of: #"\b\d{1,3}%"#, options: .regularExpression) else {
            return nil
        }

        let rawValue = self[percentRange].replacingOccurrences(of: "%", with: "")
        return Double(rawValue)
    }
}

final class DownloadProbeService: @unchecked Sendable {
    private let toolchainManager: ToolchainManager
    private let processRunner: ProcessRunner

    init(toolchainManager: ToolchainManager, processRunner: ProcessRunner) {
        self.toolchainManager = toolchainManager
        self.processRunner = processRunner
    }

    func probe(urlString: String) async throws -> MediaMetadata {
        let toolURL = try toolchainManager.executableURL(for: .ytDlp)
        let denoURL = try toolchainManager.executableURL(for: .deno)
        let toolsDirectoryURL = try toolchainManager.toolsDirectoryURL()
        let result = try await processRunner.run(
            ProcessCommand(
                executableURL: toolURL,
                arguments: ["--js-runtimes", "deno:\(denoURL.path)", "-J", "--no-playlist", "--skip-download", urlString],
                environment: Self.runtimeEnvironment(toolsDirectoryURL: toolsDirectoryURL)
            )
        )

        guard let data = result.stdout.data(using: .utf8) else {
            throw ProcessRunnerError.launchFailed("yt-dlp returned unreadable JSON metadata.")
        }

        let probe = try JSONDecoder().decode(YTDLPProbeResponse.self, from: data)
        let formats = (probe.formats ?? []).map { format -> DownloadFormatOption in
            let resolution = format.resolution?.trimmedNonEmpty
            let note = format.format_note?.trimmedNonEmpty
            let formatName = [resolution, note, format.ext?.uppercased()]
                .compactMap { $0 }
                .joined(separator: " • ")

            return DownloadFormatOption(
                id: format.format_id,
                ext: format.ext ?? "bin",
                displayName: formatName.isEmpty ? format.format_id : formatName,
                resolution: resolution,
                note: note,
                sizeBytes: format.filesize,
                fps: format.fps,
                hasVideo: (format.vcodec?.trimmedNonEmpty ?? "none") != "none",
                hasAudio: (format.acodec?.trimmedNonEmpty ?? "none") != "none"
            )
        }

        return MediaMetadata(
            source: .remote(probe.webpage_url ?? urlString),
            title: probe.title ?? urlString,
            duration: probe.duration,
            thumbnailURL: URL(string: probe.thumbnail ?? ""),
            extractor: probe.extractor,
            formats: formats
        )
    }

    private static func runtimeEnvironment(toolsDirectoryURL: URL) -> [String: String] {
        ["PATH": "\(toolsDirectoryURL.path):/usr/bin:/bin:/usr/sbin:/sbin"]
    }
}

final class DownloadService: @unchecked Sendable {
    private let toolchainManager: ToolchainManager
    private let processRunner: ProcessRunner

    init(toolchainManager: ToolchainManager, processRunner: ProcessRunner) {
        self.toolchainManager = toolchainManager
        self.processRunner = processRunner
    }

    func buildCommand(
        for request: DownloadRequest,
        toolURL: URL,
        denoURL: URL? = nil,
        toolsDirectoryURL: URL? = nil
    ) -> ProcessCommand {
        let outputTemplate: String
        if request.filenameTemplate.contains("%(ext)s") {
            outputTemplate = request.filenameTemplate
        } else {
            outputTemplate = "\(request.filenameTemplate).%(ext)s"
        }

        var arguments = [
            "--no-playlist",
            "--newline",
            "--progress-template",
            "download:%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "--print",
            "after_move:%(filepath)s",
            "-P", request.destinationDirectory.path,
            "-o", outputTemplate
        ]

        if let denoURL {
            arguments.insert(contentsOf: ["--js-runtimes", "deno:\(denoURL.path)"], at: 0)
        }

        arguments.append(request.overwriteExisting ? "--force-overwrites" : "--no-overwrites")

        if !request.selectedFormatID.isEmpty {
            arguments.append(contentsOf: ["-f", request.selectedFormatID])
        }

        switch request.preset {
        case .mp4Video:
            arguments.append(contentsOf: ["--merge-output-format", "mp4"])
        case .mp3Audio:
            arguments.append(contentsOf: ["-x", "--audio-format", "mp3", "--audio-quality", "0"])
        case .movMaster, .trimClip, .extractAudio:
            break
        }

        if request.includeSubtitles {
            arguments.append(contentsOf: ["--write-subs", "--embed-subs", "--sub-langs", "all"])
        }

        arguments.append(request.sourceURLString)

        return ProcessCommand(
            executableURL: toolURL,
            arguments: arguments,
            environment: toolsDirectoryURL.map { Self.runtimeEnvironment(toolsDirectoryURL: $0) } ?? [:]
        )
    }

    func execute(
        request: DownloadRequest,
        onEvent: @escaping @Sendable (JobEvent) async -> Void
    ) async throws -> JobResult {
        let toolURL = try toolchainManager.executableURL(for: .ytDlp)
        let denoURL = try toolchainManager.executableURL(for: .deno)
        let toolsDirectoryURL = try toolchainManager.toolsDirectoryURL()
        let command = buildCommand(
            for: request,
            toolURL: toolURL,
            denoURL: denoURL,
            toolsDirectoryURL: toolsDirectoryURL
        )

        let result = try await processRunner.run(command) { line in
            Task {
                await onEvent(.log(line.text))
                if line.text.hasPrefix("download:") {
                    let value = line.text.replacingOccurrences(of: "download:", with: "")
                    let segments = value.split(separator: "|", omittingEmptySubsequences: false)
                    if let percentText = segments.first?
                        .replacingOccurrences(of: "%", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       let percentValue = Double(percentText) {
                        await onEvent(.progress(percentValue / 100))
                    }

                    let phaseText = segments.dropFirst().joined(separator: " • ").trimmingCharacters(in: .whitespaces)
                    if !phaseText.isEmpty {
                        await onEvent(.phase("Downloading \(phaseText)"))
                    }
                }
            }
        }

        let discoveredOutputURL = result.combinedOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .reversed()
            .compactMap { line -> URL? in
                if line.hasPrefix("file://") {
                    return URL(string: line)
                }

                guard line.hasPrefix("/") else { return nil }
                return URL(fileURLWithPath: line)
            }
            .first

        if let discoveredOutputURL {
            await onEvent(.destination(discoveredOutputURL))
        }

        return JobResult(
            outputURL: discoveredOutputURL,
            summary: discoveredOutputURL?.lastPathComponent ?? "Download finished"
        )
    }

    private static func runtimeEnvironment(toolsDirectoryURL: URL) -> [String: String] {
        ["PATH": "\(toolsDirectoryURL.path):/usr/bin:/bin:/usr/sbin:/sbin"]
    }
}

final class TranscodeService: @unchecked Sendable {
    private let toolchainManager: ToolchainManager
    private let processRunner: ProcessRunner

    init(toolchainManager: ToolchainManager, processRunner: ProcessRunner) {
        self.toolchainManager = toolchainManager
        self.processRunner = processRunner
    }

    func inspectLocalMedia(at url: URL) async throws -> MediaMetadata {
        let ffprobeURL = try toolchainManager.executableURL(for: .ffprobe)
        let result = try await processRunner.run(
            ProcessCommand(
                executableURL: ffprobeURL,
                arguments: [
                    "-v", "quiet",
                    "-print_format", "json",
                    "-show_format",
                    "-show_streams",
                    url.path
                ]
            )
        )

        guard let data = result.stdout.data(using: .utf8) else {
            throw ProcessRunnerError.launchFailed("ffprobe returned unreadable metadata.")
        }

        let response = try JSONDecoder().decode(FFprobeResponse.self, from: data)
        let firstVideo = response.streams.first(where: { $0.codec_type == "video" })
        let firstAudio = response.streams.first(where: { $0.codec_type == "audio" })
        let duration = Double(response.format.duration ?? "")
        let fileSize = Int64(response.format.size ?? "")

        return MediaMetadata(
            source: .local(url),
            title: url.lastPathComponent,
            duration: duration,
            container: response.format.format_name?.split(separator: ",").first.map(String.init),
            videoCodec: firstVideo?.codec_name,
            audioCodec: firstAudio?.codec_name,
            width: firstVideo?.width,
            height: firstVideo?.height,
            fileSize: fileSize,
            formats: []
        )
    }

    func buildCommand(for request: ConvertRequest, toolURL: URL) -> (ProcessCommand, URL) {
        let outputURL = Self.outputURL(for: request)
        let preset = request.preset
        let resolvedVideoCodec = request.videoCodecOverride?.trimmedNonEmpty ?? preset.defaultVideoCodec
        let resolvedAudioCodec = request.audioCodecOverride?.trimmedNonEmpty ?? preset.defaultAudioCodec
        let resolvedAudioBitrate = request.audioBitrateOverride?.trimmedNonEmpty ?? preset.defaultAudioBitrate

        var arguments = ["-hide_banner", request.overwriteExisting ? "-y" : "-n"]

        if request.hardwareAcceleration == .automatic, !preset.audioOnly {
            arguments.append(contentsOf: ["-hwaccel", "auto"])
        }

        arguments.append(contentsOf: ["-i", request.inputURL.path])
        arguments.append(contentsOf: ["-progress", "pipe:1", "-nostats"])

        if preset.audioOnly {
            arguments.append("-vn")
        }

        if let resolvedVideoCodec, !preset.audioOnly {
            arguments.append(contentsOf: ["-c:v", resolvedVideoCodec])
        }

        if let resolvedAudioCodec {
            arguments.append(contentsOf: ["-c:a", resolvedAudioCodec])
        }

        if let resolvedAudioBitrate {
            arguments.append(contentsOf: ["-b:a", resolvedAudioBitrate])
        }

        if preset == .mp4Video || preset == .trimClip {
            arguments.append(contentsOf: ["-movflags", "+faststart"])
        }

        arguments.append(outputURL.path)

        return (
            ProcessCommand(executableURL: toolURL, arguments: arguments),
            outputURL
        )
    }

    func execute(
        request: ConvertRequest,
        metadata: MediaMetadata?,
        onEvent: @escaping @Sendable (JobEvent) async -> Void
    ) async throws -> JobResult {
        let ffmpegURL = try toolchainManager.executableURL(for: .ffmpeg)
        let inspectedMetadata: MediaMetadata
        if let metadata {
            inspectedMetadata = metadata
        } else {
            inspectedMetadata = try await inspectLocalMedia(at: request.inputURL)
        }
        let (command, outputURL) = buildCommand(for: request, toolURL: ffmpegURL)
        let duration = inspectedMetadata.duration ?? 0

        _ = try await processRunner.run(command) { line in
            Task {
                await onEvent(.log(line.text))

                if line.text.hasPrefix("out_time_ms="), duration > 0 {
                    let rawValue = line.text.replacingOccurrences(of: "out_time_ms=", with: "")
                    if let microseconds = Double(rawValue) {
                        await onEvent(.progress(min(1, microseconds / 1_000_000 / duration)))
                    }
                }

                if line.text.hasPrefix("progress=") {
                    await onEvent(.phase("Transcoding \(request.preset.title.lowercased())"))
                }
            }
        }

        await onEvent(.destination(outputURL))
        return JobResult(outputURL: outputURL, summary: outputURL.lastPathComponent)
    }

    static func outputURL(for request: ConvertRequest) -> URL {
        let fileStem = Formatters.filenameStem(for: request.inputURL)
        let suffix = request.preset.defaultFilenameSuffix
        let `extension` = request.containerOverride?.trimmedNonEmpty ?? request.preset.defaultExtension
        return request.destinationDirectory
            .appendingPathComponent("\(fileStem)-\(suffix)")
            .appendingPathExtension(`extension`)
    }
}

final class TrimService: @unchecked Sendable {
    private let toolchainManager: ToolchainManager
    private let processRunner: ProcessRunner

    init(toolchainManager: ToolchainManager, processRunner: ProcessRunner) {
        self.toolchainManager = toolchainManager
        self.processRunner = processRunner
    }

    func makePlan(request: TrimRequest, metadata: MediaMetadata?) -> TrimPlan {
        let sourceContainer = metadata?.container?.lowercased()
        let destinationContainer = request.preset.defaultExtension.lowercased()
        let startsAtBeginning = request.range.start <= 0.05
        let canStreamCopy = request.allowFastCopy
            && startsAtBeginning
            && sourceContainer == destinationContainer
            && !request.preset.audioOnly

        if canStreamCopy {
            return TrimPlan(
                strategy: .streamCopy,
                reason: "The clip starts at the beginning and keeps the same container, so ffmpeg can copy streams without re-encoding."
            )
        }

        return TrimPlan(
            strategy: .reencode,
            reason: "This clip needs precise in and out points or a new container, so ffmpeg should re-encode the export."
        )
    }

    func buildCommand(
        for request: TrimRequest,
        metadata: MediaMetadata?,
        toolURL: URL
    ) -> (ProcessCommand, URL, TrimPlan) {
        let plan = makePlan(request: request, metadata: metadata)
        let outputURL = Self.outputURL(for: request)
        var arguments = ["-hide_banner", request.overwriteExisting ? "-y" : "-n"]

        arguments.append(contentsOf: [
            "-ss", String(request.range.start),
            "-to", String(request.range.end),
            "-i", request.inputURL.path,
            "-progress", "pipe:1",
            "-nostats"
        ])

        switch plan.strategy {
        case .streamCopy:
            arguments.append(contentsOf: ["-c", "copy"])
        case .reencode:
            if let videoCodec = request.preset.defaultVideoCodec {
                arguments.append(contentsOf: ["-c:v", videoCodec])
            }

            if let audioCodec = request.preset.defaultAudioCodec {
                arguments.append(contentsOf: ["-c:a", audioCodec])
            }

            if let bitrate = request.preset.defaultAudioBitrate {
                arguments.append(contentsOf: ["-b:a", bitrate])
            }

            if request.preset == .trimClip {
                arguments.append(contentsOf: ["-movflags", "+faststart"])
            }
        }

        arguments.append(outputURL.path)
        return (ProcessCommand(executableURL: toolURL, arguments: arguments), outputURL, plan)
    }

    func execute(
        request: TrimRequest,
        metadata: MediaMetadata?,
        onEvent: @escaping @Sendable (JobEvent) async -> Void
    ) async throws -> JobResult {
        let ffmpegURL = try toolchainManager.executableURL(for: .ffmpeg)
        let (command, outputURL, plan) = buildCommand(for: request, metadata: metadata, toolURL: ffmpegURL)

        _ = try await processRunner.run(command) { line in
            Task {
                await onEvent(.log(line.text))
                await onEvent(.phase(plan.strategy == .streamCopy ? "Copying clip" : "Encoding clip"))

                if line.text.hasPrefix("out_time_ms="), request.range.duration > 0 {
                    let rawValue = line.text.replacingOccurrences(of: "out_time_ms=", with: "")
                    if let microseconds = Double(rawValue) {
                        await onEvent(.progress(min(1, microseconds / 1_000_000 / request.range.duration)))
                    }
                }
            }
        }

        await onEvent(.destination(outputURL))
        return JobResult(outputURL: outputURL, summary: "\(outputURL.lastPathComponent) • \(plan.strategy.rawValue)")
    }

    static func outputURL(for request: TrimRequest) -> URL {
        let fileStem = Formatters.filenameStem(for: request.inputURL)
        return request.destinationDirectory
            .appendingPathComponent("\(fileStem)-clip")
            .appendingPathExtension(request.preset.defaultExtension)
    }
}

final class TranscriptionService: @unchecked Sendable {
    private let toolchainManager: ToolchainManager
    private let processRunner: ProcessRunner
    private let temporaryDirectory: URL
    private let fileManager: FileManager

    init(
        toolchainManager: ToolchainManager,
        processRunner: ProcessRunner,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) {
        self.toolchainManager = toolchainManager
        self.processRunner = processRunner
        self.temporaryDirectory = temporaryDirectory
        self.fileManager = fileManager
    }

    func buildExtractionCommand(
        for request: TranscribeRequest,
        metadata: MediaMetadata?,
        toolURL: URL
    ) -> (ProcessCommand, URL) {
        let outputURL = Self.temporaryAudioURL(for: request, in: temporaryDirectory)
        var arguments = ["-hide_banner", "-y", "-i", request.inputURL.path]

        if metadata?.videoCodec != nil {
            arguments.append("-vn")
        }

        arguments.append(contentsOf: [
            "-map", "0:a:0",
            "-ac", "1",
            "-ar", "16000",
            "-c:a", "pcm_s16le",
            "-progress", "pipe:1",
            "-nostats",
            outputURL.path
        ])

        return (ProcessCommand(executableURL: toolURL, arguments: arguments), outputURL)
    }

    func buildTranscriptionCommand(
        for request: TranscribeRequest,
        normalizedAudioURL: URL,
        toolURL: URL,
        modelURL: URL
    ) -> (ProcessCommand, URL) {
        let outputURL = Self.outputURL(for: request)
        let outputBaseURL = outputURL.deletingPathExtension()
        let arguments = [
            "-m", modelURL.path,
            "-l", "en",
            "-f", normalizedAudioURL.path,
            "-of", outputBaseURL.path,
            request.outputFormat.whisperFlag,
            "-pp"
        ]

        return (
            ProcessCommand(executableURL: toolURL, arguments: arguments),
            outputURL
        )
    }

    func execute(
        request: TranscribeRequest,
        metadata: MediaMetadata?,
        onEvent: @escaping @Sendable (JobEvent) async -> Void
    ) async throws -> JobResult {
        let ffmpegURL = try toolchainManager.executableURL(for: .ffmpeg)
        let whisperURL = try toolchainManager.executableURL(for: .whisperCLI)
        let modelURL = try toolchainManager.assetURL(for: .whisperBaseEnglishModel)
        _ = toolchainManager.optionalAssetURL(for: .whisperBaseEnglishCoreML)

        let outputURL = Self.outputURL(for: request)
        let tempAudioURL = Self.temporaryAudioURL(for: request, in: temporaryDirectory)

        if fileManager.fileExists(atPath: outputURL.path) {
            if request.overwriteExisting {
                try? fileManager.removeItem(at: outputURL)
            } else {
                throw ProcessRunnerError.launchFailed("Transcript already exists at \(outputURL.path).")
            }
        }

        try? fileManager.createDirectory(at: request.destinationDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        var shouldRemoveOutputOnFailure = false
        defer {
            try? fileManager.removeItem(at: tempAudioURL)
        }

        do {
            await onEvent(.phase("Preparing audio"))
            let (extractionCommand, normalizedAudioURL) = buildExtractionCommand(for: request, metadata: metadata, toolURL: ffmpegURL)

            await onEvent(.phase("Extracting audio"))
            _ = try await processRunner.run(extractionCommand) { line in
                Task {
                    await onEvent(.log(line.text))

                    if line.text.hasPrefix("out_time_ms="), let duration = metadata?.duration, duration > 0 {
                        let rawValue = line.text.replacingOccurrences(of: "out_time_ms=", with: "")
                        if let microseconds = Double(rawValue) {
                            let normalized = min(1, microseconds / 1_000_000 / duration)
                            await onEvent(.progress(normalized * 0.2))
                        }
                    }
                }
            }

            try Task.checkCancellation()

            let (transcriptionCommand, transcriptURL) = buildTranscriptionCommand(
                for: request,
                normalizedAudioURL: normalizedAudioURL,
                toolURL: whisperURL,
                modelURL: modelURL
            )

            shouldRemoveOutputOnFailure = true
            await onEvent(.phase("Transcribing"))
            _ = try await processRunner.run(transcriptionCommand) { line in
                Task {
                    await onEvent(.log(line.text))

                    if let percentage = line.text.firstPercentageValue {
                        let normalized = min(1, max(0, percentage / 100))
                        await onEvent(.progress(0.2 + normalized * 0.75))
                    }
                }
            }

            await onEvent(.phase("Writing transcript"))
            await onEvent(.progress(1))
            await onEvent(.destination(transcriptURL))
            return JobResult(outputURL: transcriptURL, summary: transcriptURL.lastPathComponent)
        } catch {
            if shouldRemoveOutputOnFailure, fileManager.fileExists(atPath: outputURL.path) {
                try? fileManager.removeItem(at: outputURL)
            }

            throw error
        }
    }

    static func outputURL(for request: TranscribeRequest) -> URL {
        let fileStem = Formatters.filenameStem(for: request.inputURL)
        return request.destinationDirectory
            .appendingPathComponent("\(fileStem)-transcript")
            .appendingPathExtension(request.outputFormat.fileExtension)
    }

    static func temporaryAudioURL(for request: TranscribeRequest, in temporaryDirectory: URL) -> URL {
        let fileStem = Formatters.filenameStem(for: request.inputURL)
        return temporaryDirectory
            .appendingPathComponent("\(fileStem)-transcription-source")
            .appendingPathExtension("wav")
    }
}

final class ThumbnailService: @unchecked Sendable {
    func generateThumbnails(for url: URL, duration: TimeInterval, count: Int = 8) async -> [ThumbnailFrame] {
        guard duration > 0 else { return [] }

        return await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = .init(width: 320, height: 180)

            let step = duration / Double(max(count, 1))
            var frames: [ThumbnailFrame] = []

            for index in 0 ..< count {
                let second = min(duration, (Double(index) + 0.5) * step)
                let time = CMTime(seconds: second, preferredTimescale: 600)
                guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
                    continue
                }

                frames.append(
                    ThumbnailFrame(
                        time: second,
                        image: NSImage(cgImage: cgImage, size: .zero)
                    )
                )
            }

            return frames
        }.value
    }
}

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

private struct JobStagingWorkspace {
    let url: URL
    let fileManager: FileManager

    init(label: String, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        self.url = fileManager.temporaryDirectory
            .appendingPathComponent("MediaGetterJobs", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? fileManager.removeItem(at: url)
    }

    func stagedURL(for finalURL: URL) -> URL {
        url.appendingPathComponent(finalURL.lastPathComponent)
    }

    func commitFile(from stagedURL: URL, to destinationURL: URL, overwriteExisting: Bool) throws -> URL {
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: destinationURL.path) {
            guard overwriteExisting else {
                throw ProcessRunnerError.launchFailed("File already exists at \(destinationURL.path).")
            }

            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagedURL)
        } else {
            try fileManager.moveItem(at: stagedURL, to: destinationURL)
        }

        return destinationURL
    }

    func commitArtifacts(
        _ artifacts: [JobArtifact],
        to destinationDirectory: URL,
        overwriteExisting: Bool
    ) throws -> [JobArtifact] {
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        if !overwriteExisting {
            for artifact in artifacts {
                let destinationURL = destinationDirectory.appendingPathComponent(artifact.url.lastPathComponent)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    throw ProcessRunnerError.launchFailed("File already exists at \(destinationURL.path).")
                }
            }
        }

        return try artifacts.map { artifact in
            let destinationURL = destinationDirectory.appendingPathComponent(artifact.url.lastPathComponent)
            let committedURL = try commitFile(
                from: artifact.url,
                to: destinationURL,
                overwriteExisting: overwriteExisting
            )
            return JobArtifact(
                kind: artifact.kind,
                url: committedURL,
                displayName: artifact.displayName,
                isPrimary: artifact.isPrimary
            )
        }
    }
}

final class DownloadProbeService: @unchecked Sendable {
    private let toolchainManager: ToolchainManager
    private let processRunner: ProcessRunner

    init(toolchainManager: ToolchainManager, processRunner: ProcessRunner) {
        self.toolchainManager = toolchainManager
        self.processRunner = processRunner
    }

    func buildCommand(
        urlString: String,
        auth: ResolvedDownloadAuth?,
        toolURL: URL,
        denoURL: URL,
        toolsDirectoryURL: URL
    ) -> ProcessCommand {
        var arguments = [
            "--js-runtimes", "deno:\(denoURL.path)",
            "-J",
            "--no-playlist",
            "--skip-download"
        ]

        arguments.append(contentsOf: DownloadAuthCommandBuilder.arguments(for: auth))
        arguments.append(urlString)

        return ProcessCommand(
            executableURL: toolURL,
            arguments: arguments,
            environment: Self.runtimeEnvironment(toolsDirectoryURL: toolsDirectoryURL)
        )
    }

    func probe(urlString: String, auth: ResolvedDownloadAuth? = nil) async throws -> MediaMetadata {
        let toolURL = try toolchainManager.executableURL(for: .ytDlp)
        let denoURL = try toolchainManager.executableURL(for: .deno)
        let toolsDirectoryURL = try toolchainManager.toolsDirectoryURL()
        let result = try await processRunner.run(
            buildCommand(
                urlString: urlString,
                auth: auth,
                toolURL: toolURL,
                denoURL: denoURL,
                toolsDirectoryURL: toolsDirectoryURL
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
    struct DirectorySnapshotEntry: Equatable {
        var path: String
        var sizeBytes: Int64?
        var modificationDate: Date?

        var url: URL {
            URL(fileURLWithPath: path)
        }
    }

    private let toolchainManager: ToolchainManager
    private let processRunner: ProcessRunner
    private let fileManager: FileManager

    init(
        toolchainManager: ToolchainManager,
        processRunner: ProcessRunner,
        fileManager: FileManager = .default
    ) {
        self.toolchainManager = toolchainManager
        self.processRunner = processRunner
        self.fileManager = fileManager
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

        arguments.append(contentsOf: DownloadAuthCommandBuilder.arguments(for: request.resolvedAuth))

        switch request.preset {
        case .mp4Video:
            arguments.append(contentsOf: ["--merge-output-format", "mp4"])
        case .mp3Audio:
            arguments.append(contentsOf: ["-x", "--audio-format", "mp3", "--audio-quality", "0"])
        case .movMaster, .trimClip, .extractAudio:
            break
        }

        if request.subtitleWorkflow.requestsSourceSubtitles {
            arguments.append(contentsOf: ["--write-subs", "--sub-langs", "all"])
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
        let staging = try JobStagingWorkspace(label: "download", fileManager: fileManager)
        defer { staging.cleanup() }
        var stagedRequest = request
        stagedRequest.destinationDirectory = staging.url
        let command = buildCommand(
            for: stagedRequest,
            toolURL: toolURL,
            denoURL: denoURL,
            toolsDirectoryURL: toolsDirectoryURL
        )
        let beforeSnapshot = snapshotDirectory(staging.url)

        await onEvent(.stage(.downloading))
        await onEvent(.phase("Downloading media"))
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

        let afterSnapshot = snapshotDirectory(staging.url)

        let stagedOutputURL = result.combinedOutput
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

        let artifacts = detectArtifacts(
            before: beforeSnapshot,
            after: afterSnapshot,
            primaryOutputURL: stagedOutputURL
        )
        let committedArtifacts = try staging.commitArtifacts(
            artifacts,
            to: request.destinationDirectory,
            overwriteExisting: request.overwriteExisting
        )
        if let outputURL = committedArtifacts.first(where: \.isPrimary)?.url ?? committedArtifacts.first?.url {
            await onEvent(.destination(outputURL))
        }

        return JobResult(
            artifacts: committedArtifacts,
            summary: committedArtifacts.first(where: \.isPrimary)?.url.lastPathComponent ?? "Download finished"
        )
    }

    func snapshotDirectory(_ directoryURL: URL) -> [DirectorySnapshotEntry] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return fileURLs.compactMap { fileURL in
            guard let values = try? fileURL.resourceValues(forKeys: keys), values.isRegularFile == true else {
                return nil
            }

            return DirectorySnapshotEntry(
                path: fileURL.path,
                sizeBytes: values.fileSize.map(Int64.init),
                modificationDate: values.contentModificationDate
            )
        }
        .sorted { $0.path < $1.path }
    }

    func detectArtifacts(
        before: [DirectorySnapshotEntry],
        after: [DirectorySnapshotEntry],
        primaryOutputURL: URL?
    ) -> [JobArtifact] {
        let beforeByPath = Dictionary(uniqueKeysWithValues: before.map { ($0.path, $0) })
        let changedURLs = after.compactMap { entry -> URL? in
            guard beforeByPath[entry.path] != entry else { return nil }
            return entry.url
        }

        let resolvedPrimaryURL = primaryOutputURL ?? changedURLs.first(where: { !Self.isSubtitleURL($0) })
        var artifacts: [JobArtifact] = []
        if let resolvedPrimaryURL {
            artifacts.append(JobArtifact(kind: .media, url: resolvedPrimaryURL, isPrimary: true))
        }

        guard let resolvedPrimaryURL else { return artifacts }
        let subtitleURLs = changedURLs
            .filter { $0.path != resolvedPrimaryURL.path }
            .filter(Self.isSubtitleURL(_:))
            .filter { Self.matchesSubtitleSidecar($0, for: resolvedPrimaryURL) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        artifacts.append(
            contentsOf: subtitleURLs.map { JobArtifact(kind: .subtitle, url: $0, isPrimary: false) }
        )
        return artifacts
    }

    private static func runtimeEnvironment(toolsDirectoryURL: URL) -> [String: String] {
        ["PATH": "\(toolsDirectoryURL.path):/usr/bin:/bin:/usr/sbin:/sbin"]
    }

    private static func isSubtitleURL(_ url: URL) -> Bool {
        subtitleExtensions.contains(url.pathExtension.lowercased())
    }

    private static func matchesSubtitleSidecar(_ subtitleURL: URL, for primaryOutputURL: URL) -> Bool {
        let primaryStem = Formatters.filenameStem(for: primaryOutputURL)
        let subtitleStem = Formatters.filenameStem(for: subtitleURL)
        let separators = [".", "-", "_"]

        if subtitleStem == primaryStem {
            return true
        }

        return separators.contains { separator in
            subtitleStem.hasPrefix(primaryStem + separator)
        }
    }

    private static let subtitleExtensions: Set<String> = [
        "srt",
        "vtt",
        "ass",
        "ssa",
        "sub",
        "lrc",
        "ttml"
    ]
}

final class TranscodeService: @unchecked Sendable {
    private let toolchainManager: ToolchainManager
    private let processRunner: ProcessRunner
    private let fileManager: FileManager

    init(
        toolchainManager: ToolchainManager,
        processRunner: ProcessRunner,
        fileManager: FileManager = .default
    ) {
        self.toolchainManager = toolchainManager
        self.processRunner = processRunner
        self.fileManager = fileManager
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
        let staging = try JobStagingWorkspace(label: "convert", fileManager: fileManager)
        defer { staging.cleanup() }
        var stagedRequest = request
        stagedRequest.destinationDirectory = staging.url
        let (command, stagedOutputURL) = buildCommand(for: stagedRequest, toolURL: ffmpegURL)
        let outputURL = Self.outputURL(for: request)
        let duration = inspectedMetadata.duration ?? 0

        await onEvent(.stage(.transcoding))
        await onEvent(.phase("Transcoding \(request.preset.title.lowercased())"))
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

        await onEvent(.stage(.writingOutput))
        let committedURL = try staging.commitFile(
            from: stagedOutputURL,
            to: outputURL,
            overwriteExisting: request.overwriteExisting
        )
        await onEvent(.destination(committedURL))
        return JobResult(outputURL: committedURL, summary: committedURL.lastPathComponent)
    }

    func buildSubtitleNormalizationCommand(
        inputURL: URL,
        outputURL: URL,
        toolURL: URL
    ) -> ProcessCommand {
        ProcessCommand(
            executableURL: toolURL,
            arguments: [
                "-hide_banner",
                "-y",
                "-i", inputURL.path,
                outputURL.path
            ]
        )
    }

    func normalizeSubtitleToSRT(
        subtitleURL: URL,
        mediaURL: URL,
        overwriteExisting: Bool,
        onEvent: @escaping @Sendable (JobEvent) async -> Void
    ) async throws -> URL {
        let outputURL = Self.subtitleSidecarURL(for: mediaURL)
        if subtitleURL.path == outputURL.path {
            return outputURL
        }

        if fileManager.fileExists(atPath: outputURL.path) {
            if overwriteExisting {
                // Replace only after the staged normalization succeeds.
            } else {
                throw ProcessRunnerError.launchFailed("Subtitle file already exists at \(outputURL.path).")
            }
        }

        let staging = try JobStagingWorkspace(label: "subtitle-normalize", fileManager: fileManager)
        defer { staging.cleanup() }
        let stagedOutputURL = staging.stagedURL(for: outputURL)

        await onEvent(.stage(.normalizingSubtitles))
        await onEvent(.phase("Writing .srt subtitles"))
        if subtitleURL.pathExtension.lowercased() == "srt" {
            try fileManager.copyItem(at: subtitleURL, to: stagedOutputURL)
            let committedURL = try staging.commitFile(
                from: stagedOutputURL,
                to: outputURL,
                overwriteExisting: overwriteExisting
            )
            await onEvent(.progress(1))
            return committedURL
        }

        let ffmpegURL = try toolchainManager.executableURL(for: .ffmpeg)
        let command = buildSubtitleNormalizationCommand(inputURL: subtitleURL, outputURL: stagedOutputURL, toolURL: ffmpegURL)

        _ = try await processRunner.run(command) { line in
            Task { await onEvent(.log(line.text)) }
        }

        let committedURL = try staging.commitFile(
            from: stagedOutputURL,
            to: outputURL,
            overwriteExisting: overwriteExisting
        )
        await onEvent(.progress(1))
        return committedURL
    }

    func buildBurnedSubtitleCommand(
        inputURL: URL,
        subtitleURL: URL,
        outputURL: URL,
        preset: OutputPresetID,
        toolURL: URL
    ) -> ProcessCommand {
        let videoCodec = preset.defaultVideoCodec ?? "libx264"
        var arguments = [
            "-hide_banner",
            "-y",
            "-i", inputURL.path,
            "-map", "0:v:0",
            "-map", "0:a?",
            "-sn",
            "-vf", Self.subtitleFilterArgument(for: subtitleURL),
            "-progress", "pipe:1",
            "-nostats",
            "-c:v", videoCodec,
            "-c:a", "copy"
        ]

        if preset == .mp4Video || preset == .trimClip {
            arguments.append(contentsOf: ["-movflags", "+faststart"])
        }

        arguments.append(outputURL.path)
        return ProcessCommand(executableURL: toolURL, arguments: arguments)
    }

    func burnSubtitles(
        into mediaURL: URL,
        subtitleURL: URL,
        preset: OutputPresetID,
        onEvent: @escaping @Sendable (JobEvent) async -> Void
    ) async throws -> URL {
        let ffmpegURL = try toolchainManager.executableURL(for: .ffmpeg)
        let duration = (try? await inspectLocalMedia(at: mediaURL))?.duration ?? 0
        let staging = try JobStagingWorkspace(label: "caption-burn", fileManager: fileManager)
        defer { staging.cleanup() }
        let temporaryOutputURL = staging.stagedURL(for: Self.temporaryBurnedMediaURL(for: mediaURL))

        let command = buildBurnedSubtitleCommand(
            inputURL: mediaURL,
            subtitleURL: subtitleURL,
            outputURL: temporaryOutputURL,
            preset: preset,
            toolURL: ffmpegURL
        )

        do {
            await onEvent(.stage(.burningCaptions))
            await onEvent(.phase("Burning captions into video"))
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
                        await onEvent(.phase("Burning captions into video"))
                    }
                }
            }

            _ = try fileManager.replaceItemAt(mediaURL, withItemAt: temporaryOutputURL)
            await onEvent(.progress(1))
            return mediaURL
        } catch {
            throw error
        }
    }

    static func outputURL(for request: ConvertRequest) -> URL {
        let fileStem = Formatters.filenameStem(for: request.inputURL)
        let suffix = request.preset.defaultFilenameSuffix
        let `extension` = request.containerOverride?.trimmedNonEmpty ?? request.preset.defaultExtension
        return request.destinationDirectory
            .appendingPathComponent("\(fileStem)-\(suffix)")
            .appendingPathExtension(`extension`)
    }

    static func subtitleSidecarURL(for mediaURL: URL) -> URL {
        mediaURL
            .deletingPathExtension()
            .appendingPathExtension("srt")
    }

    static func subtitleSidecarURL(
        for mediaURL: URL,
        outputFormat: TranscriptionOutputFormat
    ) -> URL {
        mediaURL
            .deletingPathExtension()
            .appendingPathExtension(outputFormat.fileExtension)
    }

    private static func temporaryBurnedMediaURL(for mediaURL: URL) -> URL {
        mediaURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(Formatters.filenameStem(for: mediaURL))-caption-burn")
            .appendingPathExtension(mediaURL.pathExtension)
    }

    private static func subtitleFilterArgument(for subtitleURL: URL) -> String {
        let escapedPath = subtitleURL.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: ",", with: "\\,")
        return "subtitles='\(escapedPath)'"
    }
}

final class TrimService: @unchecked Sendable {
    private let toolchainManager: ToolchainManager
    private let processRunner: ProcessRunner
    private let fileManager: FileManager

    init(
        toolchainManager: ToolchainManager,
        processRunner: ProcessRunner,
        fileManager: FileManager = .default
    ) {
        self.toolchainManager = toolchainManager
        self.processRunner = processRunner
        self.fileManager = fileManager
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
        let staging = try JobStagingWorkspace(label: "trim", fileManager: fileManager)
        defer { staging.cleanup() }
        var stagedRequest = request
        stagedRequest.destinationDirectory = staging.url
        let (command, stagedOutputURL, plan) = buildCommand(for: stagedRequest, metadata: metadata, toolURL: ffmpegURL)
        let outputURL = Self.outputURL(for: request)

        await onEvent(.stage(.trimming))
        await onEvent(.phase(plan.strategy == .streamCopy ? "Copying clip" : "Encoding clip"))
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

        await onEvent(.stage(.writingOutput))
        let committedURL = try staging.commitFile(
            from: stagedOutputURL,
            to: outputURL,
            overwriteExisting: request.overwriteExisting
        )
        await onEvent(.destination(committedURL))
        return JobResult(outputURL: committedURL, summary: "\(committedURL.lastPathComponent) • \(plan.strategy.rawValue)")
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
        toolURL: URL,
        temporaryDirectoryURL: URL? = nil
    ) -> (ProcessCommand, URL) {
        let outputURL = Self.temporaryAudioURL(for: request, in: temporaryDirectoryURL ?? temporaryDirectory)
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
        return (
            buildTranscriptionCommand(
                normalizedAudioURL: normalizedAudioURL,
                outputURL: outputURL,
                outputFormat: request.outputFormat,
                toolURL: toolURL,
                modelURL: modelURL
            ),
            outputURL
        )
    }

    func buildTranscriptionCommand(
        normalizedAudioURL: URL,
        outputURL: URL,
        outputFormat: TranscriptionOutputFormat,
        toolURL: URL,
        modelURL: URL
    ) -> ProcessCommand {
        let outputBaseURL = outputURL.deletingPathExtension()
        let arguments = [
            "-m", modelURL.path,
            "-l", "en",
            "-f", normalizedAudioURL.path,
            "-of", outputBaseURL.path,
            outputFormat.whisperFlag,
            "-pp"
        ]

        return ProcessCommand(executableURL: toolURL, arguments: arguments)
    }

    func execute(
        request: TranscribeRequest,
        metadata: MediaMetadata?,
        onEvent: @escaping @Sendable (JobEvent) async -> Void
    ) async throws -> JobResult {
        try await execute(
            inputURL: request.inputURL,
            metadata: metadata,
            outputURL: Self.outputURL(for: request),
            outputFormat: request.outputFormat,
            overwriteExisting: request.overwriteExisting,
            onEvent: onEvent
        )
    }

    func execute(
        inputURL: URL,
        metadata: MediaMetadata?,
        outputURL: URL,
        outputFormat: TranscriptionOutputFormat,
        overwriteExisting: Bool,
        onEvent: @escaping @Sendable (JobEvent) async -> Void
    ) async throws -> JobResult {
        let ffmpegURL = try toolchainManager.executableURL(for: .ffmpeg)
        let whisperURL = try toolchainManager.executableURL(for: .whisperCLI)
        let modelURL = try toolchainManager.assetURL(for: .whisperBaseEnglishModel)
        _ = toolchainManager.optionalAssetURL(for: .whisperBaseEnglishCoreML)

        let request = TranscribeRequest(
            inputURL: inputURL,
            destinationDirectory: outputURL.deletingLastPathComponent(),
            outputFormat: outputFormat,
            overwriteExisting: overwriteExisting
        )
        let isSubtitleOutput = outputFormat.isSubtitleFormat
        let outputLabel = isSubtitleOutput ? "Subtitle file" : "Transcript"

        if fileManager.fileExists(atPath: outputURL.path) {
            if overwriteExisting {
                // Replace only after the staged transcription succeeds.
            } else {
                throw ProcessRunnerError.launchFailed("\(outputLabel) already exists at \(outputURL.path).")
            }
        }

        let staging = try JobStagingWorkspace(label: isSubtitleOutput ? "subtitles" : "transcribe", fileManager: fileManager)
        defer { staging.cleanup() }
        let stagedOutputURL = staging.stagedURL(for: outputURL)

        var shouldRemoveOutputOnFailure = false

        do {
            await onEvent(.stage(isSubtitleOutput ? .generatingSubtitles : .preparing))
            await onEvent(.phase(isSubtitleOutput ? "Preparing subtitles" : "Preparing audio"))
            let (extractionCommand, normalizedAudioURL) = buildExtractionCommand(
                for: request,
                metadata: metadata,
                toolURL: ffmpegURL,
                temporaryDirectoryURL: staging.url
            )

            await onEvent(.stage(.extractingAudio))
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

            let transcriptionCommand = buildTranscriptionCommand(
                normalizedAudioURL: normalizedAudioURL,
                outputURL: stagedOutputURL,
                outputFormat: outputFormat,
                toolURL: whisperURL,
                modelURL: modelURL
            )

            shouldRemoveOutputOnFailure = true
            await onEvent(.stage(isSubtitleOutput ? .generatingSubtitles : .transcribing))
            await onEvent(.phase(isSubtitleOutput ? "Generating subtitles" : "Transcribing"))
            _ = try await processRunner.run(transcriptionCommand) { line in
                Task {
                    await onEvent(.log(line.text))

                    if let percentage = line.text.firstPercentageValue {
                        let normalized = min(1, max(0, percentage / 100))
                        await onEvent(.progress(0.2 + normalized * 0.75))
                    }
                }
            }

            await onEvent(.stage(.writingOutput))
            await onEvent(.phase(isSubtitleOutput ? "Writing subtitles" : "Writing transcript"))
            let committedURL = try staging.commitFile(
                from: stagedOutputURL,
                to: outputURL,
                overwriteExisting: overwriteExisting
            )
            await onEvent(.progress(1))
            await onEvent(.destination(committedURL))
            return JobResult(
                outputURL: committedURL,
                summary: outputURL.lastPathComponent,
                artifactKind: outputFormat.artifactKind
            )
        } catch {
            if shouldRemoveOutputOnFailure, fileManager.fileExists(atPath: stagedOutputURL.path) {
                try? fileManager.removeItem(at: stagedOutputURL)
            }

            throw error
        }
    }

    static func outputURL(for request: TranscribeRequest) -> URL {
        outputURL(
            for: request.inputURL,
            destinationDirectory: request.destinationDirectory,
            outputFormat: request.outputFormat
        )
    }

    static func outputURL(
        for inputURL: URL,
        destinationDirectory: URL,
        outputFormat: TranscriptionOutputFormat,
        outputStem: String? = nil
    ) -> URL {
        let resolvedStem = outputStem ?? "\(Formatters.filenameStem(for: inputURL))-transcript"
        return destinationDirectory
            .appendingPathComponent(resolvedStem)
            .appendingPathExtension(outputFormat.fileExtension)
    }

    static func temporaryAudioURL(for request: TranscribeRequest, in temporaryDirectory: URL) -> URL {
        temporaryAudioURL(for: request.inputURL, in: temporaryDirectory)
    }

    static func temporaryAudioURL(for inputURL: URL, in temporaryDirectory: URL) -> URL {
        let fileStem = Formatters.filenameStem(for: inputURL)
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

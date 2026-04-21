import Foundation
import XCTest
@testable import MediaGetter

final class MediaGetterTests: XCTestCase {
    @MainActor
    func testAppUpdateManagerDisabledModeIsNoOp() {
        let updater = FakeAppUpdater(
            canCheckForUpdates: true,
            automaticallyChecksForUpdates: true,
            automaticallyDownloadsUpdates: true,
            allowsAutomaticUpdates: true
        )
        let manager = AppUpdateManager(
            updater: updater,
            updaterEnabledOverride: false
        )

        XCTAssertFalse(manager.isUpdaterEnabled)
        XCTAssertFalse(manager.canCheckForUpdates)
        XCTAssertFalse(manager.automaticallyChecksForUpdates)
        XCTAssertFalse(manager.automaticallyDownloadsUpdates)
        XCTAssertFalse(manager.canConfigureAutomaticUpdateChecks)
        XCTAssertFalse(manager.canConfigureAutomaticDownloads)
        XCTAssertEqual(manager.updatesUnavailableMessage, "Updates are only available in release builds.")

        manager.checkForUpdates()
        manager.automaticallyChecksForUpdates = true
        manager.automaticallyDownloadsUpdates = true

        XCTAssertEqual(updater.checkForUpdatesCallCount, 0)
        XCTAssertFalse(manager.automaticallyChecksForUpdates)
        XCTAssertFalse(manager.automaticallyDownloadsUpdates)
    }

    @MainActor
    func testAppUpdateManagerSyncsStateFromInjectedUpdater() {
        let updater = FakeAppUpdater(
            canCheckForUpdates: false,
            automaticallyChecksForUpdates: false,
            automaticallyDownloadsUpdates: false,
            allowsAutomaticUpdates: false
        )
        let manager = AppUpdateManager(
            updater: updater,
            updaterEnabledOverride: true
        )

        updater.publishState(
            canCheckForUpdates: true,
            automaticallyChecksForUpdates: true,
            automaticallyDownloadsUpdates: false,
            allowsAutomaticUpdates: true
        )

        XCTAssertTrue(manager.isUpdaterEnabled)
        XCTAssertTrue(manager.canCheckForUpdates)
        XCTAssertTrue(manager.automaticallyChecksForUpdates)
        XCTAssertFalse(manager.automaticallyDownloadsUpdates)
        XCTAssertTrue(manager.canConfigureAutomaticUpdateChecks)
        XCTAssertTrue(manager.canConfigureAutomaticDownloads)
        XCTAssertNil(manager.updatesUnavailableMessage)
    }

    @MainActor
    func testAppUpdateManagerPropagatesAutomaticCheckChanges() {
        let updater = FakeAppUpdater(
            canCheckForUpdates: true,
            automaticallyChecksForUpdates: false,
            automaticallyDownloadsUpdates: false,
            allowsAutomaticUpdates: true
        )
        let manager = AppUpdateManager(
            updater: updater,
            updaterEnabledOverride: true
        )

        manager.automaticallyChecksForUpdates = true

        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        XCTAssertTrue(manager.automaticallyChecksForUpdates)
    }

    @MainActor
    func testAppUpdateManagerPropagatesAutomaticDownloadChanges() {
        let updater = FakeAppUpdater(
            canCheckForUpdates: true,
            automaticallyChecksForUpdates: true,
            automaticallyDownloadsUpdates: false,
            allowsAutomaticUpdates: true
        )
        let manager = AppUpdateManager(
            updater: updater,
            updaterEnabledOverride: true
        )

        manager.automaticallyDownloadsUpdates = true
        manager.checkForUpdates()

        XCTAssertTrue(updater.automaticallyDownloadsUpdates)
        XCTAssertTrue(manager.automaticallyDownloadsUpdates)
        XCTAssertEqual(updater.checkForUpdatesCallCount, 1)
    }

    func testParseVersions() {
        XCTAssertEqual(ToolchainManager.parseVersion(tool: .ytDlp, output: "2026.04.01\n"), "2026.04.01")
        XCTAssertEqual(ToolchainManager.parseVersion(tool: .ffmpeg, output: "ffmpeg version 7.2.0 Copyright\n"), "7.2.0 Copyright")
        XCTAssertEqual(ToolchainManager.parseVersion(tool: .ffprobe, output: "ffprobe version 7.2.0-static\n"), "7.2.0-static")
        XCTAssertEqual(ToolchainManager.parseVersion(tool: .deno, output: "deno 2.7.12\n"), "2.7.12")
        XCTAssertEqual(ToolchainManager.parseVersion(tool: .whisperCLI, output: "usage: whisper-cli\n"), "Installed")
    }

    func testToolchainParsesArchitectureAndDependencyPolicies() {
        XCTAssertEqual(
            ToolchainManager.parseArchitecture(fileDescription: "Mach-O 64-bit executable arm64"),
            .arm64
        )
        XCTAssertEqual(
            ToolchainManager.parseArchitecture(fileDescription: "Mach-O universal binary with 2 architectures"),
            .universal
        )
        XCTAssertEqual(
            ToolchainManager.parseArchitecture(fileDescription: "Python script text executable"),
            .script
        )

        XCTAssertTrue(ToolchainManager.isAllowedDependencyPath("/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation"))
        XCTAssertTrue(ToolchainManager.isAllowedDependencyPath("@executable_path/../Frameworks/libfoo.dylib"))
        XCTAssertFalse(ToolchainManager.isAllowedDependencyPath("/opt/homebrew/lib/libfoo.dylib"))
    }

    func testToolchainThrowsWhenToolMissing() throws {
        let tempDirectory = try makeTemporaryDirectory()
        let toolchain = ToolchainManager(overrideToolsDirectory: tempDirectory)

        XCTAssertThrowsError(try toolchain.executableURL(for: .ffmpeg)) { error in
            XCTAssertEqual(error as? ToolchainError, .toolMissing(.ffmpeg, tempDirectory.appendingPathComponent("ffmpeg").path))
        }
    }

    func testToolchainThrowsWhenModelMissing() throws {
        let tempTools = try makeTemporaryDirectory()
        let tempModels = try makeTemporaryDirectory()
        let toolchain = ToolchainManager(overrideToolsDirectory: tempTools, overrideModelsDirectory: tempModels)

        XCTAssertThrowsError(try toolchain.assetURL(for: .whisperBaseEnglishModel)) { error in
            XCTAssertEqual(
                error as? ToolchainError,
                .assetMissing(.whisperBaseEnglishModel, tempModels.appendingPathComponent("ggml-base.en.bin").path)
            )
        }
    }

    func testDownloadCommandUsesExpectedFlags() {
        let service = DownloadService(
            toolchainManager: ToolchainManager(overrideToolsDirectory: FileManager.default.temporaryDirectory),
            processRunner: ProcessRunner()
        )
        let toolURL = URL(fileURLWithPath: "/tmp/yt-dlp")
        let denoURL = URL(fileURLWithPath: "/tmp/deno")
        let toolsDirectoryURL = URL(fileURLWithPath: "/tmp/tools", isDirectory: true)
        let command = service.buildCommand(
            for: DownloadRequest(
                sourceURLString: "https://example.com/watch?v=123",
                destinationDirectory: URL(fileURLWithPath: "/tmp/downloads", isDirectory: true),
                selectedFormatID: "137+140",
                preset: .mp4Video,
                subtitleWorkflow: SubtitleWorkflowOptions(
                    sourcePolicy: .preferSourceThenGenerate,
                    outputFormat: .srt
                ),
                filenameTemplate: "%(title)s",
                overwriteExisting: true
            ),
            toolURL: toolURL,
            denoURL: denoURL,
            toolsDirectoryURL: toolsDirectoryURL
        )

        XCTAssertEqual(command.executableURL, toolURL)
        XCTAssertTrue(command.arguments.contains("--js-runtimes"))
        XCTAssertTrue(command.arguments.contains("deno:/tmp/deno"))
        XCTAssertTrue(command.arguments.contains("--merge-output-format"))
        XCTAssertTrue(command.arguments.contains("mp4"))
        XCTAssertTrue(command.arguments.contains("--write-subs"))
        XCTAssertFalse(command.arguments.contains("--embed-subs"))
        XCTAssertTrue(command.arguments.contains("137+140"))
        XCTAssertEqual(command.environment["PATH"], "/tmp/tools:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testDownloadArtifactDetectionCapturesSubtitleSidecars() {
        let service = DownloadService(
            toolchainManager: ToolchainManager(overrideToolsDirectory: FileManager.default.temporaryDirectory),
            processRunner: ProcessRunner()
        )

        let before = [
            DownloadService.DirectorySnapshotEntry(
                path: "/tmp/downloads/sample-output.mp4",
                sizeBytes: 10,
                modificationDate: .distantPast
            )
        ]
        let after = [
            DownloadService.DirectorySnapshotEntry(
                path: "/tmp/downloads/sample-output.mp4",
                sizeBytes: 20,
                modificationDate: .now
            ),
            DownloadService.DirectorySnapshotEntry(
                path: "/tmp/downloads/sample-output.en.vtt",
                sizeBytes: 8,
                modificationDate: .now
            )
        ]

        let artifacts = service.detectArtifacts(
            before: before,
            after: after,
            primaryOutputURL: URL(fileURLWithPath: "/tmp/downloads/sample-output.mp4")
        )

        XCTAssertEqual(artifacts.count, 2)
        XCTAssertEqual(artifacts.first?.kind, .media)
        XCTAssertEqual(artifacts.last?.kind, .subtitle)
        XCTAssertEqual(artifacts.last?.url.lastPathComponent, "sample-output.en.vtt")
    }

    func testTranscodeCommandUsesPresetDefaults() {
        let service = TranscodeService(
            toolchainManager: ToolchainManager(overrideToolsDirectory: FileManager.default.temporaryDirectory),
            processRunner: ProcessRunner()
        )
        let toolURL = URL(fileURLWithPath: "/tmp/ffmpeg")
        let (command, outputURL) = service.buildCommand(
            for: ConvertRequest(
                inputURL: URL(fileURLWithPath: "/tmp/source.mov"),
                destinationDirectory: URL(fileURLWithPath: "/tmp/exports", isDirectory: true),
                preset: .extractAudio,
                subtitleWorkflow: .off(format: .srt),
                containerOverride: nil,
                videoCodecOverride: nil,
                audioCodecOverride: nil,
                audioBitrateOverride: nil,
                overwriteExisting: true,
                hardwareAcceleration: .automatic
            ),
            toolURL: toolURL
        )

        XCTAssertEqual(outputURL.path, "/tmp/exports/source-audio.mp3")
        XCTAssertTrue(command.arguments.contains("-vn"))
        XCTAssertTrue(command.arguments.contains("libmp3lame"))
    }

    func testTrimPlanPrefersStreamCopyAtBeginning() {
        let service = TrimService(
            toolchainManager: ToolchainManager(overrideToolsDirectory: FileManager.default.temporaryDirectory),
            processRunner: ProcessRunner()
        )

        let metadata = MediaMetadata(
            source: .local(URL(fileURLWithPath: "/tmp/source.mp4")),
            title: "source.mp4",
            duration: 120,
            container: "mp4",
            videoCodec: "h264",
            audioCodec: "aac"
        )

        let copyPlan = service.makePlan(
            request: TrimRequest(
                inputURL: URL(fileURLWithPath: "/tmp/source.mp4"),
                destinationDirectory: URL(fileURLWithPath: "/tmp"),
                preset: .trimClip,
                subtitleWorkflow: .off(format: .srt),
                range: TrimRange(start: 0, end: 12),
                allowFastCopy: true,
                overwriteExisting: true
            ),
            metadata: metadata
        )

        let reencodePlan = service.makePlan(
            request: TrimRequest(
                inputURL: URL(fileURLWithPath: "/tmp/source.mp4"),
                destinationDirectory: URL(fileURLWithPath: "/tmp"),
                preset: .trimClip,
                subtitleWorkflow: .off(format: .srt),
                range: TrimRange(start: 5, end: 12),
                allowFastCopy: true,
                overwriteExisting: true
            ),
            metadata: metadata
        )

        XCTAssertEqual(copyPlan.strategy, .streamCopy)
        XCTAssertEqual(reencodePlan.strategy, .reencode)
    }

    func testTranscriptionExtractionCommandUsesExpectedFlags() {
        let service = makeTranscriptionService()
        let toolURL = URL(fileURLWithPath: "/tmp/ffmpeg")
        let request = TranscribeRequest(
            inputURL: URL(fileURLWithPath: "/tmp/interview.mov"),
            destinationDirectory: URL(fileURLWithPath: "/tmp/exports", isDirectory: true),
            outputFormat: .txt,
            overwriteExisting: true
        )

        let (command, tempAudioURL) = service.buildExtractionCommand(
            for: request,
            metadata: MediaMetadata(
                source: .local(request.inputURL),
                title: "interview.mov",
                duration: 42,
                container: "mov",
                videoCodec: "h264",
                audioCodec: "aac"
            ),
            toolURL: toolURL
        )

        XCTAssertEqual(command.executableURL, toolURL)
        XCTAssertTrue(command.arguments.contains("-ar"))
        XCTAssertTrue(command.arguments.contains("16000"))
        XCTAssertTrue(command.arguments.contains("-ac"))
        XCTAssertTrue(command.arguments.contains("1"))
        XCTAssertTrue(command.arguments.contains("pcm_s16le"))
        XCTAssertEqual(tempAudioURL.lastPathComponent, "interview-transcription-source.wav")
    }

    func testTranscriptionCommandUsesExpectedFlags() throws {
        let tempModels = try makeTemporaryDirectory()
        let service = makeTranscriptionService()
        let request = TranscribeRequest(
            inputURL: URL(fileURLWithPath: "/tmp/interview.mov"),
            destinationDirectory: URL(fileURLWithPath: "/tmp/exports", isDirectory: true),
            outputFormat: .srt,
            overwriteExisting: true
        )
        let normalizedAudioURL = URL(fileURLWithPath: "/tmp/interview-transcription-source.wav")
        let modelURL = tempModels.appendingPathComponent("ggml-base.en.bin")
        try Data("model".utf8).write(to: modelURL)

        let (command, outputURL) = service.buildTranscriptionCommand(
            for: request,
            normalizedAudioURL: normalizedAudioURL,
            toolURL: URL(fileURLWithPath: "/tmp/whisper-cli"),
            modelURL: modelURL
        )

        XCTAssertEqual(outputURL.path, "/tmp/exports/interview-transcript.srt")
        XCTAssertEqual(command.arguments[0], "-m")
        XCTAssertTrue(command.arguments.contains(modelURL.path))
        XCTAssertTrue(command.arguments.contains("--output-srt"))
        XCTAssertTrue(command.arguments.contains("/tmp/exports/interview-transcript"))
        XCTAssertTrue(command.arguments.contains("-l"))
        XCTAssertTrue(command.arguments.contains("en"))
    }

    @MainActor
    func testPreferencesStorePersistsSubtitleDefaults() {
        let suiteName = "MediaGetterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = PreferencesStore(defaults: defaults)
        XCTAssertEqual(store.defaultDownloadSubtitlePolicy, .preferSourceThenGenerate)
        XCTAssertEqual(store.defaultSubtitleOutputFormat, .srt)
        XCTAssertFalse(store.defaultConvertAutoSubtitles)
        XCTAssertFalse(store.defaultTrimAutoSubtitles)

        store.defaultDownloadSubtitlePolicy = .generateOnly
        store.defaultConvertAutoSubtitles = true
        store.defaultTrimAutoSubtitles = true
        store.defaultSubtitleOutputFormat = .vtt

        let reloaded = PreferencesStore(defaults: defaults)
        XCTAssertEqual(reloaded.defaultDownloadSubtitlePolicy, .generateOnly)
        XCTAssertTrue(reloaded.defaultConvertAutoSubtitles)
        XCTAssertTrue(reloaded.defaultTrimAutoSubtitles)
        XCTAssertEqual(reloaded.defaultSubtitleOutputFormat, .vtt)
    }

    @MainActor
    func testAutoSubtitleFollowUpUsesFallbackPolicyWhenNoSourceSubtitleArtifactsExist() {
        let appState = AppState(
            preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: "MediaGetterTests.\(UUID().uuidString)")!)
        )
        let outputURL = URL(fileURLWithPath: "/tmp/sample-output.mp4")
        let workflowID = UUID()
        let request = DownloadRequest(
            sourceURLString: "https://example.com/video",
            destinationDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            selectedFormatID: "best",
            preset: .mp4Video,
            subtitleWorkflow: SubtitleWorkflowOptions(
                sourcePolicy: .preferSourceThenGenerate,
                outputFormat: .srt
            ),
            filenameTemplate: "%(title)s",
            overwriteExisting: true
        )
        let job = JobRecord(
            id: UUID(),
            request: JobRequest(
                workflowID: workflowID,
                kind: .download,
                title: "Sample",
                subtitle: OutputPresetID.mp4Video.title,
                source: .remote("https://example.com/video"),
                preset: .mp4Video,
                transcriptionOutputFormat: nil,
                payload: .download(request)
            ),
            status: .completed,
            progress: 1,
            phase: outputURL.lastPathComponent,
            logs: [],
            artifacts: [JobArtifact(kind: .media, url: outputURL, isPrimary: true)],
            createdAt: Date(),
            startedAt: Date(),
            completedAt: Date(),
            errorMessage: nil
        )

        let followUp = appState.makeAutoSubtitleJobRequest(for: job)

        XCTAssertEqual(followUp?.workflowID, workflowID)
        XCTAssertEqual(followUp?.parentJobID, job.id)
        XCTAssertEqual(followUp?.subtitle, "Auto subtitles (.srt)")
        XCTAssertEqual(followUp?.transcriptionOutputFormat, .srt)
    }

    @MainActor
    func testAutoSubtitleFollowUpSkipsWhenSourceSubtitleArtifactsExist() {
        let appState = AppState(
            preferencesStore: PreferencesStore(defaults: UserDefaults(suiteName: "MediaGetterTests.\(UUID().uuidString)")!)
        )
        let outputURL = URL(fileURLWithPath: "/tmp/sample-output.mp4")
        let subtitleURL = URL(fileURLWithPath: "/tmp/sample-output.en.vtt")
        let request = DownloadRequest(
            sourceURLString: "https://example.com/video",
            destinationDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            selectedFormatID: "best",
            preset: .mp4Video,
            subtitleWorkflow: SubtitleWorkflowOptions(
                sourcePolicy: .preferSourceThenGenerate,
                outputFormat: .srt
            ),
            filenameTemplate: "%(title)s",
            overwriteExisting: true
        )
        let job = JobRecord(
            id: UUID(),
            request: JobRequest(
                kind: .download,
                title: "Sample",
                subtitle: OutputPresetID.mp4Video.title,
                source: .remote("https://example.com/video"),
                preset: .mp4Video,
                transcriptionOutputFormat: nil,
                payload: .download(request)
            ),
            status: .completed,
            progress: 1,
            phase: outputURL.lastPathComponent,
            logs: [],
            artifacts: [
                JobArtifact(kind: .media, url: outputURL, isPrimary: true),
                JobArtifact(kind: .subtitle, url: subtitleURL, isPrimary: false)
            ],
            createdAt: Date(),
            startedAt: Date(),
            completedAt: Date(),
            errorMessage: nil
        )

        XCTAssertNil(appState.makeAutoSubtitleJobRequest(for: job))
    }

    func testHistoryEntryDecodesLegacyOutputPathIntoArtifacts() throws {
        let json = """
        {
          "id": "E65094A1-1682-4F79-B07F-BD1B2C8A8E6D",
          "jobKind": "transcribe",
          "title": "Legacy Transcript",
          "subtitle": "Plain Text (.txt)",
          "source": {
            "id": "A33F72C8-5A5F-4B12-B9DD-BE8EC6923B81",
            "localFilePath": "/tmp/source.mov",
            "displayName": "source.mov"
          },
          "outputPath": "/tmp/source-transcript.txt",
          "createdAt": "2026-04-20T22:00:00Z",
          "transcriptionOutputFormat": "txt",
          "summary": "Legacy transcript"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(HistoryEntry.self, from: Data(json.utf8))

        XCTAssertEqual(entry.outputURL?.path, "/tmp/source-transcript.txt")
        XCTAssertEqual(entry.primaryArtifact?.kind, .transcript)
        XCTAssertEqual(entry.subtitleArtifacts.count, 1)
    }

    func testTranscriptionExecuteHonorsExistingOutputWhenOverwriteDisabled() async throws {
        let fixture = try makeTranscriptionFixture(
            whisperScript: """
            #!/bin/sh
            exit 0
            """
        )
        let existingOutputURL = fixture.destinationDirectory.appendingPathComponent("session-transcript.txt")
        try Data("existing transcript".utf8).write(to: existingOutputURL)

        let service = TranscriptionService(
            toolchainManager: fixture.toolchain,
            processRunner: ProcessRunner(),
            temporaryDirectory: fixture.temporaryDirectory
        )

        await XCTAssertThrowsErrorAsync(
            try await service.execute(
                request: fixture.request,
                metadata: fixture.metadata
            ) { _ in }
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Transcript already exists"))
        }
    }

    func testTranscriptionExecuteCleansUpTemporaryAudioOnFailure() async throws {
        let fixture = try makeTranscriptionFixture(
            whisperScript: """
            #!/bin/sh
            echo "progress = 30%"
            exit 1
            """
        )
        let service = TranscriptionService(
            toolchainManager: fixture.toolchain,
            processRunner: ProcessRunner(),
            temporaryDirectory: fixture.temporaryDirectory
        )

        await XCTAssertThrowsErrorAsync(
            try await service.execute(
                request: fixture.request,
                metadata: fixture.metadata
            ) { _ in }
        )

        let tempAudioURL = TranscriptionService.temporaryAudioURL(for: fixture.request, in: fixture.temporaryDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempAudioURL.path))
    }

    func testTranscriptionExecuteCleansUpTemporaryAudioOnCancellation() async throws {
        let fixture = try makeTranscriptionFixture(
            whisperScript: """
            #!/bin/sh
            output_base=""
            ext=".txt"
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -of|--output-file) output_base="$2"; shift 2 ;;
                -otxt|--output-txt) ext=".txt"; shift ;;
                -osrt|--output-srt) ext=".srt"; shift ;;
                -ovtt|--output-vtt) ext=".vtt"; shift ;;
                *) shift ;;
              esac
            done
            echo "progress = 10%"
            sleep 5
            printf 'late transcript' > "${output_base}${ext}"
            """
        )
        let service = TranscriptionService(
            toolchainManager: fixture.toolchain,
            processRunner: ProcessRunner(),
            temporaryDirectory: fixture.temporaryDirectory
        )

        let task = Task {
            try await service.execute(
                request: fixture.request,
                metadata: fixture.metadata
            ) { _ in }
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected transcription to be cancelled.")
        } catch is CancellationError {
            // Expected.
        } catch let error as ProcessRunnerError {
            switch error {
            case .nonZeroExit(let code, _):
                XCTAssertEqual(code, 15)
            default:
                XCTFail("Expected cancellation-related termination, got \(error)")
            }
        } catch {
            XCTFail("Expected cancellation-related error, got \(error)")
        }

        let tempAudioURL = TranscriptionService.temporaryAudioURL(for: fixture.request, in: fixture.temporaryDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempAudioURL.path))
    }

    private func makeTranscriptionService() -> TranscriptionService {
        TranscriptionService(
            toolchainManager: ToolchainManager(
                overrideToolsDirectory: FileManager.default.temporaryDirectory,
                overrideModelsDirectory: FileManager.default.temporaryDirectory
            ),
            processRunner: ProcessRunner()
        )
    }

    private func makeTranscriptionFixture(whisperScript: String) throws -> (
        toolchain: ToolchainManager,
        request: TranscribeRequest,
        metadata: MediaMetadata,
        temporaryDirectory: URL,
        destinationDirectory: URL
    ) {
        let root = try makeTemporaryDirectory()
        let toolsDirectory = root.appendingPathComponent("Tools", isDirectory: true)
        let modelsDirectory = root.appendingPathComponent("Models", isDirectory: true)
        let destinationDirectory = root.appendingPathComponent("Exports", isDirectory: true)
        let temporaryDirectory = root.appendingPathComponent("Temp", isDirectory: true)

        try FileManager.default.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        try writeExecutable(
            named: "ffmpeg",
            in: toolsDirectory,
            contents: """
            #!/bin/sh
            output=""
            for arg in "$@"; do
              output="$arg"
            done
            echo "out_time_ms=1000000"
            echo "progress=continue"
            printf 'wav' > "$output"
            """
        )

        try writeExecutable(named: "whisper-cli", in: toolsDirectory, contents: whisperScript)
        try Data("model".utf8).write(to: modelsDirectory.appendingPathComponent("ggml-base.en.bin"))

        let inputURL = root.appendingPathComponent("session.mov")
        try Data("media".utf8).write(to: inputURL)

        let toolchain = ToolchainManager(
            overrideToolsDirectory: toolsDirectory,
            overrideModelsDirectory: modelsDirectory
        )

        return (
            toolchain: toolchain,
            request: TranscribeRequest(
                inputURL: inputURL,
                destinationDirectory: destinationDirectory,
                outputFormat: .txt,
                overwriteExisting: false
            ),
            metadata: MediaMetadata(
                source: .local(inputURL),
                title: "session.mov",
                duration: 12,
                container: "mov",
                videoCodec: "h264",
                audioCodec: "aac"
            ),
            temporaryDirectory: temporaryDirectory,
            destinationDirectory: destinationDirectory
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeExecutable(named name: String, in directory: URL, contents: String) throws {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: ((Error) -> Void)? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw an error.", file: file, line: line)
    } catch {
        errorHandler?(error)
    }
}

@MainActor
private final class FakeAppUpdater: AppUpdaterControlling {
    var canCheckForUpdates: Bool
    var automaticallyChecksForUpdates: Bool
    var automaticallyDownloadsUpdates: Bool
    var allowsAutomaticUpdates: Bool
    private(set) var checkForUpdatesCallCount = 0

    private var observers: [@MainActor () -> Void] = []

    init(
        canCheckForUpdates: Bool,
        automaticallyChecksForUpdates: Bool,
        automaticallyDownloadsUpdates: Bool,
        allowsAutomaticUpdates: Bool
    ) {
        self.canCheckForUpdates = canCheckForUpdates
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        self.allowsAutomaticUpdates = allowsAutomaticUpdates
    }

    func checkForUpdates() {
        checkForUpdatesCallCount += 1
    }

    func installObservers(_ onChange: @escaping @MainActor () -> Void) -> [NSKeyValueObservation] {
        observers.append(onChange)
        return []
    }

    func publishState(
        canCheckForUpdates: Bool? = nil,
        automaticallyChecksForUpdates: Bool? = nil,
        automaticallyDownloadsUpdates: Bool? = nil,
        allowsAutomaticUpdates: Bool? = nil
    ) {
        if let canCheckForUpdates {
            self.canCheckForUpdates = canCheckForUpdates
        }
        if let automaticallyChecksForUpdates {
            self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
        if let automaticallyDownloadsUpdates {
            self.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
        if let allowsAutomaticUpdates {
            self.allowsAutomaticUpdates = allowsAutomaticUpdates
        }

        observers.forEach { $0() }
    }
}

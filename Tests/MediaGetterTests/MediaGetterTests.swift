import Foundation
import XCTest
@testable import MediaGetter

private final class LockedProcessOutputLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [ProcessOutputLine] = []

    func append(_ line: ProcessOutputLine) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func snapshot() -> [ProcessOutputLine] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

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

    func testProcessRunnerCapturesOutputWithoutTrailingNewline() async throws {
        let runner = ProcessRunner()
        let streamedLines = LockedProcessOutputLines()

        let result = try await runner.run(
            ProcessCommand(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'hello'; printf 'warn' >&2"]
            ),
            onOutput: { streamedLines.append($0) }
        )

        XCTAssertEqual(result.stdout, "hello")
        XCTAssertEqual(result.stderr, "warn")
        let normalizedLines = streamedLines.snapshot().sorted {
            "\($0.stream):\($0.text)" < "\($1.stream):\($1.text)"
        }
        XCTAssertEqual(
            normalizedLines,
            [
                ProcessOutputLine(stream: .stderr, text: "warn"),
                ProcessOutputLine(stream: .stdout, text: "hello"),
            ]
        )
    }

    func testProcessRunnerCancellationTerminatesAndThrowsCancellation() async throws {
        let root = try makeTemporaryDirectory()
        let markerURL = root.appendingPathComponent("started")
        let runner = ProcessRunner()
        let task = Task {
            try await runner.run(
                ProcessCommand(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        "touch '\(markerURL.path)'; sleep 20"
                    ]
                )
            )
        }

        try await waitUntilFileExists(markerURL)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        }
    }

    @MainActor
    func testQueueCancelRunningJobTransitionsThroughCancelling() async throws {
        let store = QueueStore()
        let didStart = expectation(description: "job started")
        let request = makeQueueJobRequest()

        store.setExecutor { _, _ in
            didStart.fulfill()
            try await Task.sleep(nanoseconds: 20_000_000_000)
            return JobResult(outputURL: nil, summary: "Finished")
        }

        store.enqueue(request)
        await fulfillment(of: [didStart], timeout: 2)

        store.cancel(jobID: request.id)

        XCTAssertEqual(store.jobs.count, 1)
        XCTAssertEqual(store.jobs.first?.status, .cancelling)
        XCTAssertEqual(store.jobs.first?.stage, .cancelling)
        XCTAssertTrue(store.jobs.first?.phase.contains("Cancelling") == true)
    }

    @MainActor
    func testQueueRetryReusesSameRowAndPreservesRequest() {
        let store = QueueStore()
        let request = makeQueueJobRequest()
        store.enqueue(request)
        store.cancel(jobID: request.id)

        XCTAssertEqual(store.jobs.first?.status, .cancelled)

        store.retry(jobID: request.id)

        XCTAssertEqual(store.jobs.count, 1)
        XCTAssertEqual(store.jobs.first?.id, request.id)
        XCTAssertEqual(store.jobs.first?.request, request)
        XCTAssertEqual(store.jobs.first?.status, .pending)
        XCTAssertEqual(store.jobs.first?.stage, .queued)
        XCTAssertEqual(store.jobs.first?.progress, 0)
        XCTAssertNil(store.jobs.first?.completedAt)
        XCTAssertTrue(store.jobs.first?.logs.isEmpty == true)
    }

    @MainActor
    func testAppUpdateManagerExposesRetryAfterFailure() {
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

        manager.markFailedUpdateForTesting(action: .check, message: "Network failed")

        XCTAssertEqual(manager.updatePhase, .failed)
        XCTAssertTrue(manager.canRetryUpdateSession)

        manager.retryUpdateSession()

        XCTAssertEqual(updater.checkForUpdatesCallCount, 1)
        XCTAssertEqual(manager.updatePhase, .checking)
        XCTAssertFalse(manager.canRetryUpdateSession)
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
        XCTAssertTrue(ToolBinaryArchitecture.arm64.isAppleSiliconReady)
        XCTAssertTrue(ToolBinaryArchitecture.universal.isAppleSiliconReady)
        XCTAssertFalse(ToolBinaryArchitecture.x86_64.isAppleSiliconReady)
        XCTAssertEqual(
            ToolchainManager.parseDependencyPaths(
                otoolOutput: """
                Vendor/Tools/yt-dlp (architecture x86_64):
                \t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)
                \t/usr/lib/libz.1.dylib (compatibility version 1.0.0, current version 1.2.12)
                Vendor/Tools/yt-dlp (architecture arm64):
                \t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)
                \t/usr/lib/libz.1.dylib (compatibility version 1.0.0, current version 1.2.12)
                """
            ),
            [
                "/usr/lib/libSystem.B.dylib",
                "/usr/lib/libz.1.dylib",
                "/usr/lib/libSystem.B.dylib",
                "/usr/lib/libz.1.dylib",
            ]
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
                overwriteExisting: true,
                resolvedAuth: nil
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

    func testDownloadCommandSupportsBrowserCookieImport() {
        let service = makeDownloadService()
        let command = service.buildCommand(
            for: makeDownloadRequest(
                resolvedAuth: .browser(
                    BrowserDownloadAuthConfiguration(
                        browser: .firefox,
                        profile: "Work",
                        container: "Personal"
                    )
                )
            ),
            toolURL: URL(fileURLWithPath: "/tmp/yt-dlp"),
            denoURL: URL(fileURLWithPath: "/tmp/deno"),
            toolsDirectoryURL: URL(fileURLWithPath: "/tmp/tools", isDirectory: true)
        )

        XCTAssertTrue(command.arguments.contains("--cookies-from-browser"))
        XCTAssertTrue(command.arguments.contains("firefox:Work::Personal"))
    }

    func testDownloadCommandSupportsManagedCookieFile() {
        let service = makeDownloadService()
        let command = service.buildCommand(
            for: makeDownloadRequest(resolvedAuth: .cookieFile(path: "/tmp/auth/cookies.txt")),
            toolURL: URL(fileURLWithPath: "/tmp/yt-dlp"),
            denoURL: URL(fileURLWithPath: "/tmp/deno"),
            toolsDirectoryURL: URL(fileURLWithPath: "/tmp/tools", isDirectory: true)
        )

        XCTAssertTrue(command.arguments.contains("--cookies"))
        XCTAssertTrue(command.arguments.contains("/tmp/auth/cookies.txt"))
    }

    func testDownloadCommandSupportsCookieHeaderOnly() {
        let service = makeDownloadService()
        let command = service.buildCommand(
            for: makeDownloadRequest(
                resolvedAuth: .advancedHeaders(
                    cookieHeader: "sid=abc123",
                    userAgent: nil,
                    headers: []
                )
            ),
            toolURL: URL(fileURLWithPath: "/tmp/yt-dlp"),
            denoURL: URL(fileURLWithPath: "/tmp/deno"),
            toolsDirectoryURL: URL(fileURLWithPath: "/tmp/tools", isDirectory: true)
        )

        XCTAssertTrue(command.arguments.contains("--add-header"))
        XCTAssertTrue(command.arguments.contains("Cookie:sid=abc123"))
        XCTAssertFalse(command.arguments.contains("--user-agent"))
    }

    func testDownloadCommandSupportsUserAgentAndCustomHeaders() {
        let service = makeDownloadService()
        let command = service.buildCommand(
            for: makeDownloadRequest(
                resolvedAuth: .advancedHeaders(
                    cookieHeader: "sid=abc123",
                    userAgent: "MediaGetterTest/1.0",
                    headers: [
                        DownloadHeaderField(name: "X-Test-Header", value: "enabled"),
                        DownloadHeaderField(name: "Referer", value: "https://example.com")
                    ]
                )
            ),
            toolURL: URL(fileURLWithPath: "/tmp/yt-dlp"),
            denoURL: URL(fileURLWithPath: "/tmp/deno"),
            toolsDirectoryURL: URL(fileURLWithPath: "/tmp/tools", isDirectory: true)
        )

        XCTAssertTrue(command.arguments.contains("--user-agent"))
        XCTAssertTrue(command.arguments.contains("MediaGetterTest/1.0"))
        XCTAssertTrue(command.arguments.contains("X-Test-Header:enabled"))
        XCTAssertTrue(command.arguments.contains("Referer:https://example.com"))
    }

    func testDownloadProbeAndDownloadShareAuthArgumentMapping() {
        let auth = ResolvedDownloadAuth.advancedHeaders(
            cookieHeader: "sid=abc123",
            userAgent: "MediaGetterTest/1.0",
            headers: [DownloadHeaderField(name: "X-Test-Header", value: "enabled")]
        )
        let authArguments = DownloadAuthCommandBuilder.arguments(for: auth)

        let probeService = DownloadProbeService(
            toolchainManager: ToolchainManager(overrideToolsDirectory: FileManager.default.temporaryDirectory),
            processRunner: ProcessRunner()
        )
        let probeCommand = probeService.buildCommand(
            urlString: "https://example.com/watch?v=123",
            auth: auth,
            toolURL: URL(fileURLWithPath: "/tmp/yt-dlp"),
            denoURL: URL(fileURLWithPath: "/tmp/deno"),
            toolsDirectoryURL: URL(fileURLWithPath: "/tmp/tools", isDirectory: true)
        )

        let downloadCommand = makeDownloadService().buildCommand(
            for: makeDownloadRequest(resolvedAuth: auth),
            toolURL: URL(fileURLWithPath: "/tmp/yt-dlp"),
            denoURL: URL(fileURLWithPath: "/tmp/deno"),
            toolsDirectoryURL: URL(fileURLWithPath: "/tmp/tools", isDirectory: true)
        )

        XCTAssertTrue(probeCommand.arguments.containsSubsequence(authArguments))
        XCTAssertTrue(downloadCommand.arguments.containsSubsequence(authArguments))
    }

    @MainActor
    func testAuthProfileStorePersistsProfilesAndDefaultSelection() throws {
        let root = try makeTemporaryDirectory()
        let secretStore = InMemorySecretStore()
        let store = AuthProfileStore(
            persistenceURL: root.appendingPathComponent("auth_profiles.json"),
            profilesDirectoryURL: root.appendingPathComponent("AuthProfiles", isDirectory: true),
            secretStore: secretStore
        )

        let savedProfile = try store.saveProfile(
            from: DownloadAuthProfileDraft(
                name: "Browser Profile",
                strategyKind: .browser,
                browser: .chrome,
                browserProfile: "Profile 1",
                markAsDefault: true
            )
        )

        let reloadedStore = AuthProfileStore(
            persistenceURL: root.appendingPathComponent("auth_profiles.json"),
            profilesDirectoryURL: root.appendingPathComponent("AuthProfiles", isDirectory: true),
            secretStore: secretStore
        )

        XCTAssertEqual(reloadedStore.profiles.count, 1)
        XCTAssertEqual(reloadedStore.defaultProfileID, savedProfile.id)
        XCTAssertEqual(reloadedStore.defaultProfile?.name, "Browser Profile")
    }

    @MainActor
    func testAuthProfileStoreDeletesSecretsAndManagedCookieFiles() throws {
        let root = try makeTemporaryDirectory()
        let secretStore = InMemorySecretStore()
        let store = AuthProfileStore(
            persistenceURL: root.appendingPathComponent("auth_profiles.json"),
            profilesDirectoryURL: root.appendingPathComponent("AuthProfiles", isDirectory: true),
            secretStore: secretStore
        )
        let cookieSourceURL = root.appendingPathComponent("exported-cookies.txt")
        try makeValidCookieFile(at: cookieSourceURL)

        let cookieProfile = try store.saveProfile(
            from: DownloadAuthProfileDraft(
                name: "Cookie File",
                strategyKind: .cookieFile,
                selectedCookieFilePath: cookieSourceURL.path,
                markAsDefault: false
            )
        )
        let advancedProfile = try store.saveProfile(
            from: DownloadAuthProfileDraft(
                name: "Advanced",
                strategyKind: .advancedHeaders,
                cookieHeader: "sid=abc123",
                userAgent: "MediaGetterTest/1.0",
                customHeaders: [DownloadHeaderField(name: "X-Test-Header", value: "enabled")],
                markAsDefault: false
            )
        )

        let managedCookieURL = root
            .appendingPathComponent("AuthProfiles", isDirectory: true)
            .appendingPathComponent(cookieProfile.id.uuidString, isDirectory: true)
            .appendingPathComponent("cookies.txt")

        XCTAssertTrue(FileManager.default.fileExists(atPath: managedCookieURL.path))
        XCTAssertNotNil(secretStore.secrets[advancedProfile.id.uuidString])

        try store.deleteProfile(id: cookieProfile.id)
        try store.deleteProfile(id: advancedProfile.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: managedCookieURL.path))
        XCTAssertNil(secretStore.secrets[advancedProfile.id.uuidString])
    }

    @MainActor
    func testAppStateSeedsDefaultAuthProfileAndSnapshotsResolvedAuthOnEnqueue() throws {
        let suiteName = "MediaGetterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let root = try makeTemporaryDirectory()
        let secretStore = InMemorySecretStore()
        let authStore = AuthProfileStore(
            persistenceURL: root.appendingPathComponent("auth_profiles.json"),
            profilesDirectoryURL: root.appendingPathComponent("AuthProfiles", isDirectory: true),
            secretStore: secretStore
        )
        let defaultProfile = try authStore.saveProfile(
            from: DownloadAuthProfileDraft(
                name: "Default Browser",
                strategyKind: .browser,
                browser: .safari,
                markAsDefault: true
            )
        )

        let appState = AppState(
            preferencesStore: PreferencesStore(defaults: defaults),
            historyStore: HistoryStore(persistenceURL: root.appendingPathComponent("history.json")),
            authProfileStore: authStore
        )

        XCTAssertEqual(appState.downloadDraft.selectedAuthProfileID, defaultProfile.id)

        appState.updateDownloadURL("https://example.com/watch?v=123")
        appState.downloadDraft.subtitleWorkflow = .off(format: .srt)
        appState.applySuccessfulDownloadProbe(
            metadata: MediaMetadata(
                source: .remote("https://example.com/watch?v=123"),
                title: "Example"
            ),
            resolvedAuth: try authStore.resolvedAuth(for: defaultProfile.id),
            title: "Inspection complete",
            message: "Ready to queue"
        )

        appState.enqueueDownload()

        guard case .download(let request)? = appState.queueStore.selectedJob?.request.payload else {
            return XCTFail("Expected a queued download request.")
        }

        XCTAssertEqual(
            request.resolvedAuth,
            .browser(BrowserDownloadAuthConfiguration(browser: .safari, profile: nil, container: nil))
        )
    }

    @MainActor
    func testDownloadProbeInvalidatesWhenURLChanges() throws {
        let appState = try makeIsolatedAppState()
        appState.updateDownloadURL("https://example.com/watch?v=123")
        appState.applySuccessfulDownloadProbe(
            metadata: makeDownloadMetadata(urlString: "https://example.com/watch?v=123"),
            resolvedAuth: nil,
            title: "Inspection complete",
            message: "Ready to queue"
        )

        XCTAssertNotNil(appState.downloadDraft.metadata)
        XCTAssertEqual(appState.downloadDraft.selectedFormatID, "137+140")
        XCTAssertEqual(appState.downloadDraft.lastProbedURLString, "https://example.com/watch?v=123")

        appState.updateDownloadURL("https://example.com/watch?v=456")

        XCTAssertNil(appState.downloadDraft.metadata)
        XCTAssertEqual(appState.downloadDraft.selectedFormatID, DownloadDraft.automaticFormatID)
        XCTAssertNil(appState.downloadDraft.lastProbedURLString)
        XCTAssertNil(appState.downloadDraft.probeStatusTitle)
        XCTAssertNil(appState.downloadDraft.probeStatusMessage)
    }

    @MainActor
    func testDownloadProbeInvalidatesWhenAuthChanges() throws {
        let root = try makeTemporaryDirectory()
        let secretStore = InMemorySecretStore()
        let authStore = AuthProfileStore(
            persistenceURL: root.appendingPathComponent("auth_profiles.json"),
            profilesDirectoryURL: root.appendingPathComponent("AuthProfiles", isDirectory: true),
            secretStore: secretStore
        )
        let firstProfile = try authStore.saveProfile(
            from: DownloadAuthProfileDraft(
                name: "Browser One",
                strategyKind: .browser,
                browser: .safari,
                markAsDefault: false
            )
        )
        let secondProfile = try authStore.saveProfile(
            from: DownloadAuthProfileDraft(
                name: "Browser Two",
                strategyKind: .browser,
                browser: .chrome,
                markAsDefault: false
            )
        )
        let appState = try makeIsolatedAppState(root: root, authStore: authStore)

        appState.updateDownloadURL("https://example.com/watch?v=123")
        appState.updateSelectedDownloadAuthProfileID(firstProfile.id)
        appState.applySuccessfulDownloadProbe(
            metadata: makeDownloadMetadata(urlString: "https://example.com/watch?v=123"),
            resolvedAuth: try authStore.resolvedAuth(for: firstProfile.id),
            title: "Inspection complete",
            message: "Ready to queue"
        )

        XCTAssertNotNil(appState.downloadDraft.metadata)
        XCTAssertEqual(appState.downloadDraft.selectedFormatID, "137+140")

        appState.updateSelectedDownloadAuthProfileID(secondProfile.id)

        XCTAssertNil(appState.downloadDraft.metadata)
        XCTAssertEqual(appState.downloadDraft.selectedFormatID, DownloadDraft.automaticFormatID)
        XCTAssertNil(appState.downloadDraft.lastProbedAuthFingerprint)
        XCTAssertNil(appState.downloadDraft.probeStatusTitle)
    }

    @MainActor
    func testEnqueueDownloadBlocksStaleProbeState() throws {
        let appState = try makeIsolatedAppState()
        appState.updateDownloadURL("https://example.com/watch?v=123")
        appState.downloadDraft.metadata = makeDownloadMetadata(urlString: "https://example.com/watch?v=123")
        appState.downloadDraft.lastProbedURLString = "https://example.com/watch?v=123"
        appState.downloadDraft.lastProbedAuthFingerprint = "stale-context"
        appState.downloadDraft.selectedFormatID = "137+140"

        appState.enqueueDownload()

        XCTAssertTrue(appState.queueStore.jobs.isEmpty)
        XCTAssertEqual(appState.alert?.title, "Inspect URL again")
        XCTAssertNil(appState.downloadDraft.metadata)
        XCTAssertEqual(appState.downloadDraft.selectedFormatID, DownloadDraft.automaticFormatID)
    }

    @MainActor
    func testSuccessfulDownloadProbeStampsFreshContextAndAllowsEnqueue() throws {
        let appState = try makeIsolatedAppState()
        appState.updateDownloadURL("https://example.com/watch?v=123")
        appState.applySuccessfulDownloadProbe(
            metadata: makeDownloadMetadata(urlString: "https://example.com/watch?v=123"),
            resolvedAuth: nil,
            title: "Inspection complete",
            message: "Ready to queue"
        )

        XCTAssertEqual(appState.downloadDraft.lastProbedURLString, "https://example.com/watch?v=123")
        XCTAssertNil(appState.downloadDraft.lastProbedAuthFingerprint)
        XCTAssertEqual(appState.downloadDraft.selectedFormatID, "137+140")

        appState.enqueueDownload()

        XCTAssertEqual(appState.queueStore.jobs.count, 1)
        guard case .download(let request)? = appState.queueStore.selectedJob?.request.payload else {
            return XCTFail("Expected a queued download request.")
        }

        XCTAssertEqual(request.sourceURLString, "https://example.com/watch?v=123")
        XCTAssertEqual(request.selectedFormatID, "137+140")
        XCTAssertNil(appState.alert)
    }

    @MainActor
    func testDroppedURLQueuesDownloadWithoutInspection() throws {
        let appState = try makeIsolatedAppState()
        appState.downloadDraft.selectedPreset = .mp4Video

        appState.enqueueDroppedDownloadText("Watch later: https://example.com/watch?v=drag")

        XCTAssertEqual(appState.queueStore.jobs.count, 1)
        XCTAssertEqual(appState.selectedSection, .queue)
        guard case .download(let request)? = appState.queueStore.selectedJob?.request.payload else {
            return XCTFail("Expected a queued download request.")
        }

        XCTAssertEqual(request.sourceURLString, "https://example.com/watch?v=drag")
        XCTAssertEqual(request.selectedFormatID, DownloadDraft.automaticFormatID)
        XCTAssertEqual(request.preset, .mp4Video)
        XCTAssertNil(appState.alert)
    }

    @MainActor
    func testDroppedFilesQueueConvertRequestsUsingCurrentPreset() throws {
        let appState = try makeIsolatedAppState()
        appState.convertDraft.selectedPreset = .extractAudio
        let firstURL = URL(fileURLWithPath: "/tmp/session-one.mov")
        let secondURL = URL(fileURLWithPath: "/tmp/session-two.mkv")

        appState.enqueueDroppedFiles([firstURL, secondURL], for: .convert)

        XCTAssertEqual(appState.queueStore.jobs.count, 2)
        XCTAssertEqual(appState.selectedSection, .queue)
        let requests = appState.queueStore.jobs.compactMap { job -> ConvertRequest? in
            guard case .convert(let request) = job.request.payload else { return nil }
            return request
        }
        XCTAssertEqual(Set(requests.map(\.inputURL)), Set([firstURL, secondURL]))
        XCTAssertTrue(requests.allSatisfy { $0.preset == .extractAudio })
        XCTAssertNil(appState.alert)
    }

    @MainActor
    func testDroppedFilesQueueTranscriptionRequestsUsingCurrentFormat() throws {
        let appState = try makeIsolatedAppState()
        appState.toolVersions = [
            ToolVersionInfo(
                tool: .whisperCLI,
                versionString: "usage: whisper-cli",
                executablePath: "/tmp/whisper-cli",
                architecture: .arm64,
                sourceDescription: "Test",
                linkageStatus: .selfContained,
                linkageDetail: "System libraries only",
                isVendored: true,
                isSelfContained: true
            )
        ]
        appState.bundledAssetStatuses = [
            BundledAssetStatus(
                asset: .whisperBaseEnglishModel,
                isAvailable: true,
                path: "/tmp/ggml-base.en.bin",
                detail: "Available"
            )
        ]
        appState.transcribeDraft.outputFormat = .vtt
        let inputURL = URL(fileURLWithPath: "/tmp/interview.mp4")

        appState.enqueueDroppedFiles([inputURL], for: .transcribe)

        XCTAssertEqual(appState.queueStore.jobs.count, 1)
        XCTAssertEqual(appState.selectedSection, .queue)
        guard case .transcribe(let request)? = appState.queueStore.selectedJob?.request.payload else {
            return XCTFail("Expected a queued transcription request.")
        }

        XCTAssertEqual(request.inputURL, inputURL)
        XCTAssertEqual(request.outputFormat, .vtt)
        XCTAssertNil(appState.alert)
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

    func testDownloadFailureDoesNotCommitPartialStagedOutput() async throws {
        let root = try makeTemporaryDirectory()
        let toolsDirectory = root.appendingPathComponent("Tools", isDirectory: true)
        let destinationDirectory = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try writeExecutable(
            named: "yt-dlp",
            in: toolsDirectory,
            contents: """
            #!/bin/sh
            destination=""
            previous=""
            for arg in "$@"; do
              if [ "$previous" = "-P" ]; then
                destination="$arg"
              fi
              previous="$arg"
            done
            mkdir -p "$destination"
            printf 'partial media' > "$destination/sample.mp4"
            echo "$destination/sample.mp4"
            exit 1
            """
        )
        try writeExecutable(
            named: "deno",
            in: toolsDirectory,
            contents: """
            #!/bin/sh
            exit 0
            """
        )
        let service = DownloadService(
            toolchainManager: ToolchainManager(overrideToolsDirectory: toolsDirectory),
            processRunner: ProcessRunner()
        )

        await XCTAssertThrowsErrorAsync(
            try await service.execute(
                request: DownloadRequest(
                    sourceURLString: "https://example.com/video",
                    destinationDirectory: destinationDirectory,
                    selectedFormatID: "best",
                    preset: .mp4Video,
                    subtitleWorkflow: .off(format: .srt),
                    filenameTemplate: "%(title)s",
                    overwriteExisting: true,
                    resolvedAuth: nil
                )
            ) { _ in }
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationDirectory.appendingPathComponent("sample.mp4").path))
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
        XCTAssertFalse(command.arguments.contains("-hwaccel"))
    }

    func testTranscodeCommandUsesHardwareAccelerationForVideoPresets() {
        let service = TranscodeService(
            toolchainManager: ToolchainManager(overrideToolsDirectory: FileManager.default.temporaryDirectory),
            processRunner: ProcessRunner()
        )
        let toolURL = URL(fileURLWithPath: "/tmp/ffmpeg")
        let (command, _) = service.buildCommand(
            for: ConvertRequest(
                inputURL: URL(fileURLWithPath: "/tmp/source.mov"),
                destinationDirectory: URL(fileURLWithPath: "/tmp/exports", isDirectory: true),
                preset: .mp4Video,
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

        XCTAssertTrue(command.arguments.contains("-hwaccel"))
        XCTAssertTrue(command.arguments.contains("auto"))
    }

    func testTranscodeFailurePreservesExistingDestinationFile() async throws {
        let root = try makeTemporaryDirectory()
        let toolsDirectory = root.appendingPathComponent("Tools", isDirectory: true)
        let destinationDirectory = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try writeExecutable(
            named: "ffmpeg",
            in: toolsDirectory,
            contents: """
            #!/bin/sh
            output=""
            for arg in "$@"; do
              output="$arg"
            done
            printf 'partial export' > "$output"
            exit 1
            """
        )
        let inputURL = root.appendingPathComponent("source.mov")
        try Data("media".utf8).write(to: inputURL)
        let existingOutputURL = destinationDirectory.appendingPathComponent("source-audio.mp3")
        try Data("original export".utf8).write(to: existingOutputURL)
        let service = TranscodeService(
            toolchainManager: ToolchainManager(overrideToolsDirectory: toolsDirectory),
            processRunner: ProcessRunner()
        )

        await XCTAssertThrowsErrorAsync(
            try await service.execute(
                request: ConvertRequest(
                    inputURL: inputURL,
                    destinationDirectory: destinationDirectory,
                    preset: .extractAudio,
                    subtitleWorkflow: .off(format: .srt),
                    containerOverride: nil,
                    videoCodecOverride: nil,
                    audioCodecOverride: nil,
                    audioBitrateOverride: nil,
                    overwriteExisting: true,
                    hardwareAcceleration: .automatic
                ),
                metadata: MediaMetadata(source: .local(inputURL), title: "source.mov", duration: 5)
            ) { _ in }
        )

        XCTAssertEqual(try String(contentsOf: existingOutputURL), "original export")
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

    func testSubtitleWorkflowBurnFlagDefaultsToFalse() {
        let workflow = SubtitleWorkflowOptions(sourcePolicy: .generateOnly, outputFormat: .srt)
        XCTAssertFalse(workflow.burnInVideo)
    }

    func testTranscodeServiceBuildBurnedSubtitleCommandUsesExpectedFlags() {
        let service = TranscodeService(
            toolchainManager: ToolchainManager(overrideToolsDirectory: FileManager.default.temporaryDirectory),
            processRunner: ProcessRunner()
        )

        let command = service.buildBurnedSubtitleCommand(
            inputURL: URL(fileURLWithPath: "/tmp/source-video.mp4"),
            subtitleURL: URL(fileURLWithPath: "/tmp/source-video.srt"),
            outputURL: URL(fileURLWithPath: "/tmp/source-video-caption-burn.mp4"),
            preset: .mp4Video,
            toolURL: URL(fileURLWithPath: "/tmp/ffmpeg")
        )

        XCTAssertTrue(command.arguments.contains("-vf"))
        XCTAssertTrue(command.arguments.contains(where: { $0.contains("subtitles='") }))
        XCTAssertTrue(command.arguments.contains("-c:v"))
        XCTAssertTrue(command.arguments.contains("libx264"))
        XCTAssertTrue(command.arguments.contains("-c:a"))
        XCTAssertTrue(command.arguments.contains("copy"))
        XCTAssertTrue(command.arguments.contains("+faststart"))
    }

    func testTranscodeServiceNormalizesCanonicalSRTSidecarWithoutFFmpegWhenSourceIsAlreadySRT() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let mediaURL = tempDirectory.appendingPathComponent("sample-output.mp4")
        let sourceSubtitleURL = tempDirectory.appendingPathComponent("sample-output.en.srt")
        try Data("media".utf8).write(to: mediaURL)
        try Data("1\n00:00:00,000 --> 00:00:01,000\nHello\n".utf8).write(to: sourceSubtitleURL)

        let service = TranscodeService(
            toolchainManager: ToolchainManager(overrideToolsDirectory: tempDirectory),
            processRunner: ProcessRunner()
        )

        let canonicalURL = try await service.normalizeSubtitleToSRT(
            subtitleURL: sourceSubtitleURL,
            mediaURL: mediaURL,
            overwriteExisting: true
        ) { _ in }

        XCTAssertEqual(canonicalURL.lastPathComponent, "sample-output.srt")
        XCTAssertEqual(try String(contentsOf: canonicalURL), try String(contentsOf: sourceSubtitleURL))
    }

    func testTranscriptionExecuteSupportsCustomSubtitleSidecarPath() async throws {
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
            echo "progress = 100%"
            printf 'subtitle sidecar' > "${output_base}${ext}"
            """
        )

        let service = TranscriptionService(
            toolchainManager: fixture.toolchain,
            processRunner: ProcessRunner(),
            temporaryDirectory: fixture.temporaryDirectory
        )
        let outputURL = fixture.destinationDirectory.appendingPathComponent("session-video.srt")

        let result = try await service.execute(
            inputURL: fixture.request.inputURL,
            metadata: fixture.metadata,
            outputURL: outputURL,
            outputFormat: .srt,
            overwriteExisting: true
        ) { _ in }

        XCTAssertEqual(result.outputURL, outputURL)
        XCTAssertEqual(outputURL.lastPathComponent, "session-video.srt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
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

    func testTranscriptionFailurePreservesExistingOutputWhenOverwriteEnabled() async throws {
        let fixture = try makeTranscriptionFixture(
            whisperScript: """
            #!/bin/sh
            output_base=""
            ext=".txt"
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -of|--output-file) output_base="$2"; shift 2 ;;
                -otxt|--output-txt) ext=".txt"; shift ;;
                *) shift ;;
              esac
            done
            printf 'partial transcript' > "${output_base}${ext}"
            exit 1
            """
        )
        var request = fixture.request
        request.overwriteExisting = true
        let existingOutputURL = fixture.destinationDirectory.appendingPathComponent("session-transcript.txt")
        try Data("original transcript".utf8).write(to: existingOutputURL)

        let service = TranscriptionService(
            toolchainManager: fixture.toolchain,
            processRunner: ProcessRunner(),
            temporaryDirectory: fixture.temporaryDirectory
        )

        await XCTAssertThrowsErrorAsync(
            try await service.execute(
                request: request,
                metadata: fixture.metadata
            ) { _ in }
        )

        XCTAssertEqual(try String(contentsOf: existingOutputURL), "original transcript")
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

    private func makeDownloadService() -> DownloadService {
        DownloadService(
            toolchainManager: ToolchainManager(overrideToolsDirectory: FileManager.default.temporaryDirectory),
            processRunner: ProcessRunner()
        )
    }

    private func makeDownloadRequest(resolvedAuth: ResolvedDownloadAuth?) -> DownloadRequest {
        DownloadRequest(
            sourceURLString: "https://example.com/watch?v=123",
            destinationDirectory: URL(fileURLWithPath: "/tmp/downloads", isDirectory: true),
            selectedFormatID: "137+140",
            preset: .mp4Video,
            subtitleWorkflow: SubtitleWorkflowOptions(
                sourcePolicy: .preferSourceThenGenerate,
                outputFormat: .srt
            ),
            filenameTemplate: "%(title)s",
            overwriteExisting: true,
            resolvedAuth: resolvedAuth
        )
    }

    private func makeQueueJobRequest() -> JobRequest {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mov")
        return JobRequest(
            kind: .convert,
            title: "source.mov",
            subtitle: "Audio",
            source: .local(sourceURL),
            preset: .extractAudio,
            transcriptionOutputFormat: nil,
            payload: .convert(
                ConvertRequest(
                    inputURL: sourceURL,
                    destinationDirectory: URL(fileURLWithPath: "/tmp/exports", isDirectory: true),
                    preset: .extractAudio,
                    subtitleWorkflow: .off(format: .srt),
                    containerOverride: nil,
                    videoCodecOverride: nil,
                    audioCodecOverride: nil,
                    audioBitrateOverride: nil,
                    overwriteExisting: true,
                    hardwareAcceleration: .automatic
                )
            )
        )
    }

    private func makeDownloadMetadata(urlString: String) -> MediaMetadata {
        MediaMetadata(
            source: .remote(urlString),
            title: "Example Video",
            duration: 42,
            extractor: "generic",
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
    }

    @MainActor
    private func makeIsolatedAppState(
        root: URL? = nil,
        authStore: AuthProfileStore? = nil
    ) throws -> AppState {
        let resolvedRoot: URL
        if let root {
            resolvedRoot = root
        } else {
            resolvedRoot = try makeTemporaryDirectory()
        }
        let suiteName = "MediaGetterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let preferencesStore = PreferencesStore(defaults: defaults)
        preferencesStore.defaultDownloadSubtitlePolicy = .off

        return AppState(
            preferencesStore: preferencesStore,
            historyStore: HistoryStore(persistenceURL: resolvedRoot.appendingPathComponent("history.json")),
            authProfileStore: authStore ?? AuthProfileStore(
                persistenceURL: resolvedRoot.appendingPathComponent("auth_profiles.json"),
                profilesDirectoryURL: resolvedRoot.appendingPathComponent("AuthProfiles", isDirectory: true),
                secretStore: InMemorySecretStore()
            )
        )
    }

    private func makeValidCookieFile(at url: URL) throws {
        try """
        # Netscape HTTP Cookie File
        .example.com\tTRUE\t/\tFALSE\t2145916800\tsessionid\tabc123
        """.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitUntilFileExists(_ url: URL, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTFail("Timed out waiting for \(url.path)")
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

private final class InMemorySecretStore: SecretStore {
    private(set) var secrets: [String: StoredAdvancedHeadersSecret] = [:]

    func saveAdvancedHeadersSecret(_ secret: StoredAdvancedHeadersSecret, for reference: String) throws {
        secrets[reference] = secret
    }

    func loadAdvancedHeadersSecret(for reference: String) throws -> StoredAdvancedHeadersSecret? {
        secrets[reference]
    }

    func deleteSecret(for reference: String) throws {
        secrets.removeValue(forKey: reference)
    }
}

private extension Array where Element: Equatable {
    func containsSubsequence(_ subsequence: [Element]) -> Bool {
        guard !subsequence.isEmpty, count >= subsequence.count else { return false }

        for start in 0...(count - subsequence.count) {
            if Array(self[start..<(start + subsequence.count)]) == subsequence {
                return true
            }
        }

        return false
    }
}

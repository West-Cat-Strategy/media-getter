import Foundation

final class XMediaService: @unchecked Sendable {
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

    func exportCookies(browser: XBrowser, cookieFilePath: String, onEvent: @escaping @Sendable (JobEvent) async -> Void) async throws {
        await onEvent(.phase("Exporting cookies from \(browser.title)"))
        let ytDlpURL = try toolchainManager.executableURL(for: .ytDlp)
        let cookieURL = URL(fileURLWithPath: cookieFilePath)
        try fileManager.createDirectory(at: cookieURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let arguments = [
            "--cookies-from-browser", browser.ytDlpArgument,
            "--cookies", cookieFilePath,
            "https://x.com"
        ]

        let command = ProcessCommand(executableURL: ytDlpURL, arguments: arguments)

        do {
            _ = try await processRunner.run(command) { line in
                Task { await onEvent(.log(line.text)) }
            }
        } catch {
            await onEvent(.log("Cookie export failed: \(error.localizedDescription)"))
            throw ProcessRunnerError.launchFailed("Could not export cookies from \(browser.title). Confirm the browser is installed, you are logged into X, and the cookie file path is writable.")
        }
    }

    func verifyCookies(cookieFilePath: String, onEvent: @escaping @Sendable (JobEvent) async -> Void) async throws -> Bool {
        await onEvent(.phase("Verifying cookies"))

        guard fileManager.fileExists(atPath: cookieFilePath) else {
            await onEvent(.log("Cookie file not found at \(cookieFilePath)"))
            return false
        }

        let contents = try String(contentsOfFile: cookieFilePath, encoding: .utf8)
        let hasAuthToken = contents.contains("auth_token")
        let hasCt0 = contents.contains("ct0")

        if hasAuthToken && hasCt0 {
            await onEvent(.log("Verified auth_token and ct0 in cookie file."))
            return true
        } else {
            if !hasAuthToken { await onEvent(.log("Missing auth_token in cookie file.")) }
            if !hasCt0 { await onEvent(.log("Missing ct0 in cookie file.")) }
            return false
        }
    }

    func downloadMedia(request: XMediaRequest, onEvent: @escaping @Sendable (JobEvent) async -> Void) async throws -> JobResult {
        await onEvent(.phase("Downloading media"))
        let galleryDlURL = try toolchainManager.executableURL(for: .galleryDl)

        let normalizedHandle = request.handle.hasPrefix("@") ? String(request.handle.dropFirst()) : request.handle
        let url = "https://x.com/\(normalizedHandle)/media"

        let arguments = [
            url,
            "--cookies", request.cookieFilePath,
            "-d", request.destinationDirectory.path
        ]

        let command = ProcessCommand(executableURL: galleryDlURL, arguments: arguments)

        try fileManager.createDirectory(at: request.destinationDirectory, withIntermediateDirectories: true)

        _ = try await processRunner.run(command) { line in
            Task {
                await onEvent(.log(line.text))

                // gallery-dl doesn't have a simple percentage progress for overall profile download easily parsable
                // but we can at least show it's active.
                if line.text.contains("Downloading") {
                    await onEvent(.phase("Downloading \(normalizedHandle)'s media..."))
                }

                if line.text.contains("AuthRequired") {
                    await onEvent(.log("ERROR: gallery-dl reported AuthRequired. Cookies might be invalid or expired."))
                }
            }
        }

        await onEvent(.progress(1.0))
        return JobResult(outputURL: request.destinationDirectory, summary: "Finished downloading media for @\(normalizedHandle)")
    }

    func execute(
        request: XMediaRequest,
        onEvent: @escaping @Sendable (JobEvent) async -> Void
    ) async throws -> JobResult {
        // 1. Export cookies
        try await exportCookies(browser: request.browser, cookieFilePath: request.cookieFilePath, onEvent: onEvent)

        // 2. Verify cookies
        let cookiesValid = try await verifyCookies(cookieFilePath: request.cookieFilePath, onEvent: onEvent)
        if !cookiesValid {
            throw ProcessRunnerError.launchFailed("Cookie verification failed. Please ensure you are logged into X in \(request.browser.title).")
        }

        // 3. Download media
        return try await downloadMedia(request: request, onEvent: onEvent)
    }
}

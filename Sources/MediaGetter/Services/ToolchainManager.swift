import Foundation

enum ToolchainError: LocalizedError, Equatable {
    case toolsDirectoryMissing(String)
    case modelsDirectoryMissing(String)
    case toolMissing(BundledTool, String)
    case notExecutable(BundledTool, String)
    case assetMissing(BundledAsset, String)

    var errorDescription: String? {
        switch self {
        case .toolsDirectoryMissing(let path):
            return "Bundled tools directory is missing at \(path)."
        case .modelsDirectoryMissing(let path):
            return "Bundled models directory is missing at \(path)."
        case .toolMissing(let tool, let path):
            return "Bundled tool \(tool.displayName) is missing at \(path)."
        case .notExecutable(let tool, let path):
            return "Bundled tool \(tool.displayName) is not executable at \(path)."
        case .assetMissing(let asset, let path):
            return "Bundled asset \(asset.displayName) is missing at \(path)."
        }
    }
}

struct ToolValidationReport: Equatable {
    var versions: [ToolVersionInfo]
    var issues: [String]
    var assetStatuses: [BundledAssetStatus]
}

final class ToolchainManager: @unchecked Sendable {
    private let bundle: Bundle
    private let overrideToolsDirectory: URL?
    private let overrideModelsDirectory: URL?

    init(bundle: Bundle = .main, overrideToolsDirectory: URL? = nil, overrideModelsDirectory: URL? = nil) {
        self.bundle = bundle
        self.overrideToolsDirectory = overrideToolsDirectory
        self.overrideModelsDirectory = overrideModelsDirectory
    }

    func toolsDirectoryURL() throws -> URL {
        if let overrideToolsDirectory {
            return overrideToolsDirectory
        }

        guard let resourceURL = bundle.resourceURL else {
            throw ToolchainError.toolsDirectoryMissing("Bundle resource URL unavailable")
        }

        let toolsURL = resourceURL.appendingPathComponent("Tools", isDirectory: true)
        guard FileManager.default.fileExists(atPath: toolsURL.path) else {
            throw ToolchainError.toolsDirectoryMissing(toolsURL.path)
        }
        return toolsURL
    }

    func modelsDirectoryURL() throws -> URL {
        if let overrideModelsDirectory {
            return overrideModelsDirectory
        }

        guard let resourceURL = bundle.resourceURL else {
            throw ToolchainError.modelsDirectoryMissing("Bundle resource URL unavailable")
        }

        let modelsURL = resourceURL.appendingPathComponent("Models", isDirectory: true)
        guard FileManager.default.fileExists(atPath: modelsURL.path) else {
            throw ToolchainError.modelsDirectoryMissing(modelsURL.path)
        }
        return modelsURL
    }

    func executableURL(for tool: BundledTool) throws -> URL {
        let toolsDirectory = try toolsDirectoryURL()
        let executableURL = toolsDirectory.appendingPathComponent(tool.rawValue)
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw ToolchainError.toolMissing(tool, executableURL.path)
        }

        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ToolchainError.notExecutable(tool, executableURL.path)
        }

        return executableURL
    }

    func assetURL(for asset: BundledAsset) throws -> URL {
        let expectedURL = expectedAssetURL(for: asset)
        guard FileManager.default.fileExists(atPath: expectedURL.path) else {
            throw ToolchainError.assetMissing(asset, expectedURL.path)
        }

        return expectedURL
    }

    func optionalAssetURL(for asset: BundledAsset) -> URL? {
        let expectedURL = expectedAssetURL(for: asset)
        guard FileManager.default.fileExists(atPath: expectedURL.path) else { return nil }
        return expectedURL
    }

    func validateAll(using runner: ProcessRunner) async -> ToolValidationReport {
        var versions: [ToolVersionInfo] = []
        var issues: [String] = []

        for tool in BundledTool.allCases {
            do {
                let executableURL = try executableURL(for: tool)
                let result = try await runner.run(
                    ProcessCommand(executableURL: executableURL, arguments: tool.versionArguments)
                )
                let version = Self.parseVersion(tool: tool, output: result.stdout.isEmpty ? result.stderr : result.stdout)
                let runtimeStatus = try await inspectRuntime(for: executableURL, using: runner)

                if !runtimeStatus.architecture.isAppleSiliconReady {
                    issues.append("\(tool.displayName) must be bundled as an arm64 binary. Found \(runtimeStatus.architecture.title.lowercased()).")
                }

                if !runtimeStatus.isSelfContained {
                    issues.append("\(tool.displayName) links external dependencies: \(runtimeStatus.linkageDetail)")
                }

                versions.append(
                    ToolVersionInfo(
                        tool: tool,
                        versionString: version,
                        executablePath: executableURL.path,
                        architecture: runtimeStatus.architecture,
                        sourceDescription: "Bundled from vendored toolchain",
                        linkageStatus: runtimeStatus.linkageStatus,
                        linkageDetail: runtimeStatus.linkageDetail,
                        isVendored: true,
                        isSelfContained: runtimeStatus.isSelfContained
                    )
                )
            } catch {
                if tool.requiredAtLaunch {
                    issues.append(error.localizedDescription)
                }
            }
        }

        let assetStatuses = BundledAsset.allCases.map { assetStatus(for: $0) }

        return ToolValidationReport(versions: versions, issues: issues, assetStatuses: assetStatuses)
    }

    static func parseVersion(tool: BundledTool, output: String) -> String {
        let firstLine = output
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"

        switch tool {
        case .ytDlp:
            return firstLine
        case .ffmpeg:
            return firstLine.replacingOccurrences(of: "ffmpeg version ", with: "")
        case .ffprobe:
            return firstLine.replacingOccurrences(of: "ffprobe version ", with: "")
        case .deno:
            return firstLine.replacingOccurrences(of: "deno ", with: "")
        case .whisperCLI:
            return "Installed"
        }
    }

    static func parseArchitecture(fileDescription: String) -> ToolBinaryArchitecture {
        let normalized = fileDescription.lowercased()

        if normalized.contains("script text executable") {
            return .script
        }

        if normalized.contains("universal binary") {
            return .universal
        }

        if normalized.contains("arm64") {
            return .arm64
        }

        if normalized.contains("x86_64") {
            return .x86_64
        }

        return .unknown
    }

    static func isAllowedDependencyPath(_ path: String) -> Bool {
        path.hasPrefix("/System/")
            || path.hasPrefix("/usr/lib/")
            || path.hasPrefix("@executable_path/")
            || path.hasPrefix("@loader_path/")
            || path.hasPrefix("@rpath/")
    }

    private func assetStatus(for asset: BundledAsset) -> BundledAssetStatus {
        let path = expectedAssetURL(for: asset).path
        let isAvailable = FileManager.default.fileExists(atPath: path)
        let detail: String

        if isAvailable {
            detail = asset == .whisperBaseEnglishCoreML ? "Bundled and ready for Apple Silicon acceleration." : "Bundled and ready."
        } else {
            detail = asset == .whisperBaseEnglishCoreML
                ? "Missing. Apple Silicon transcription requires the bundled Core ML encoder."
                : "Missing. Bundle this model to enable transcription."
        }

        return BundledAssetStatus(
            asset: asset,
            isAvailable: isAvailable,
            path: path,
            detail: detail
        )
    }

    private func expectedAssetURL(for asset: BundledAsset) -> URL {
        let baseURL: URL
        if let overrideModelsDirectory {
            baseURL = overrideModelsDirectory
        } else {
            let resourceURL = bundle.resourceURL ?? URL(fileURLWithPath: NSHomeDirectory())
            baseURL = resourceURL.appendingPathComponent("Models", isDirectory: true)
        }

        return baseURL.appendingPathComponent(asset.rawValue, isDirectory: asset.isDirectory)
    }

    private func inspectRuntime(for executableURL: URL, using runner: ProcessRunner) async throws -> ToolRuntimeStatus {
        let fileOutput = try await runner.run(
            ProcessCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/file"),
                arguments: ["-b", executableURL.path]
            )
        )
        let architecture = Self.parseArchitecture(fileDescription: fileOutput.stdout)

        guard architecture != .script else {
            return ToolRuntimeStatus(
                architecture: architecture,
                linkageStatus: .notApplicable,
                linkageDetail: "Native Mach-O binary required",
                isSelfContained: false
            )
        }

        let otoolOutput = try await runner.run(
            ProcessCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/otool"),
                arguments: ["-L", executableURL.path]
            )
        )

        let dependencyPaths = otoolOutput.stdout
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return trimmed.split(separator: " ").first.map(String.init)
            }

        let externalDependencies = dependencyPaths.filter { !Self.isAllowedDependencyPath($0) }
        let isSelfContained = externalDependencies.isEmpty
        let linkageStatus: ToolLinkageStatus = isSelfContained ? .selfContained : .externalDependencies
        let linkageDetail = isSelfContained ? "No Homebrew or local dylib dependencies detected." : externalDependencies.joined(separator: ", ")

        return ToolRuntimeStatus(
            architecture: architecture,
            linkageStatus: linkageStatus,
            linkageDetail: linkageDetail,
            isSelfContained: isSelfContained
        )
    }
}

private struct ToolRuntimeStatus {
    var architecture: ToolBinaryArchitecture
    var linkageStatus: ToolLinkageStatus
    var linkageDetail: String
    var isSelfContained: Bool
}

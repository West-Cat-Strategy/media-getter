import Foundation

struct ProcessCommand {
    var executableURL: URL
    var arguments: [String]
    var environment: [String: String] = [:]
    var currentDirectoryURL: URL? = nil
}

enum ProcessOutputStream {
    case stdout
    case stderr
}

struct ProcessOutputLine: Equatable {
    var stream: ProcessOutputStream
    var text: String
}

struct ProcessResult: Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var combinedOutput: String
}

enum ProcessRunnerError: LocalizedError {
    case launchFailed(String)
    case nonZeroExit(Int32, String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return message
        case .nonZeroExit(let code, let output):
            return "Process exited with code \(code): \(output)"
        }
    }
}

actor OutputCollector {
    private var stdoutLines: [String] = []
    private var stderrLines: [String] = []

    func append(_ line: String, stream: ProcessOutputStream) {
        switch stream {
        case .stdout:
            stdoutLines.append(line)
        case .stderr:
            stderrLines.append(line)
        }
    }

    func snapshot(exitCode: Int32) -> ProcessResult {
        let stdout = stdoutLines.joined(separator: "\n")
        let stderr = stderrLines.joined(separator: "\n")
        let combined = (stdoutLines + stderrLines).joined(separator: "\n")
        return ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr, combinedOutput: combined)
    }
}

final class ProcessRunner: @unchecked Sendable {
    func run(
        _ command: ProcessCommand,
        onOutput: (@Sendable (ProcessOutputLine) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let collector = OutputCollector()

        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.currentDirectoryURL = command.currentDirectoryURL

        if !command.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
        }

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutTask = Task {
            for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                await collector.append(line, stream: .stdout)
                onOutput?(ProcessOutputLine(stream: .stdout, text: line))
            }
        }

        let stderrTask = Task {
            for try await line in stderrPipe.fileHandleForReading.bytes.lines {
                await collector.append(line, stream: .stderr)
                onOutput?(ProcessOutputLine(stream: .stderr, text: line))
            }
        }

        let exitCode = try await withTaskCancellationHandler {
            try process.run()
            return try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { terminatedProcess in
                    continuation.resume(returning: terminatedProcess.terminationStatus)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
                usleep(200_000)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        stdoutPipe.fileHandleForReading.closeFile()
        stderrPipe.fileHandleForReading.closeFile()
        _ = try? await stdoutTask.value
        _ = try? await stderrTask.value

        let result = await collector.snapshot(exitCode: exitCode)

        guard exitCode == 0 else {
            throw ProcessRunnerError.nonZeroExit(exitCode, result.combinedOutput)
        }

        return result
    }
}

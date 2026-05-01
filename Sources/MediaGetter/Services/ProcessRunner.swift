import Darwin
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
    private var stdoutData = Data()
    private var stderrData = Data()

    func append(_ data: Data, stream: ProcessOutputStream) {
        switch stream {
        case .stdout:
            stdoutData.append(data)
        case .stderr:
            stderrData.append(data)
        }
    }

    func snapshot(exitCode: Int32) -> ProcessResult {
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let combined = [stdout, stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr, combinedOutput: combined)
    }
}

private final class ProcessCancellationCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private weak var process: Process?
    private var processIdentifier: pid_t?
    private var didCancel = false

    func register(_ process: Process) {
        lock.lock()
        self.process = process
        self.processIdentifier = process.processIdentifier
        let pid = process.processIdentifier
        lock.unlock()

        _ = setpgid(pid, pid)
    }

    func cancel() {
        lock.lock()
        didCancel = true
        let process = self.process
        let pid = self.processIdentifier
        lock.unlock()

        guard let process else { return }

        if let pid {
            _ = kill(-pid, SIGTERM)
        }
        if process.isRunning {
            process.terminate()
        }

        usleep(300_000)

        if let pid, process.isRunning {
            _ = kill(-pid, SIGKILL)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didCancel
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
        let cancellationCoordinator = ProcessCancellationCoordinator()

        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.currentDirectoryURL = command.currentDirectoryURL

        if !command.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
        }

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutTask = Task {
            try await Self.drain(
                handle: stdoutPipe.fileHandleForReading,
                stream: .stdout,
                collector: collector,
                onOutput: onOutput
            )
        }

        let stderrTask = Task {
            try await Self.drain(
                handle: stderrPipe.fileHandleForReading,
                stream: .stderr,
                collector: collector,
                onOutput: onOutput
            )
        }

        let exitCode = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try process.run()
            cancellationCoordinator.register(process)
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            return try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { terminatedProcess in
                    continuation.resume(returning: terminatedProcess.terminationStatus)
                }
            }
        } onCancel: {
            cancellationCoordinator.cancel()
        }

        if cancellationCoordinator.isCancelled {
            _ = try? await stdoutTask.value
            _ = try? await stderrTask.value
            throw CancellationError()
        }

        try await stdoutTask.value
        try await stderrTask.value

        let result = await collector.snapshot(exitCode: exitCode)

        guard exitCode == 0 else {
            throw ProcessRunnerError.nonZeroExit(exitCode, result.combinedOutput)
        }

        return result
    }

    private static func drain(
        handle: FileHandle,
        stream: ProcessOutputStream,
        collector: OutputCollector,
        onOutput: (@Sendable (ProcessOutputLine) -> Void)?
    ) async throws {
        var bufferedLineData = Data()

        while true {
            let chunk = try handle.read(upToCount: 4_096) ?? Data()
            if chunk.isEmpty {
                break
            }

            await collector.append(chunk, stream: stream)

            guard let onOutput else { continue }
            bufferedLineData.append(chunk)

            while let newlineIndex = bufferedLineData.firstIndex(of: 0x0A) {
                let lineData = bufferedLineData.prefix(upTo: newlineIndex)
                bufferedLineData.removeSubrange(...newlineIndex)
                onOutput(
                    ProcessOutputLine(
                        stream: stream,
                        text: String(decoding: lineData, as: UTF8.self)
                            .trimmingCharacters(in: .newlines)
                    )
                )
            }
        }

        guard let onOutput, !bufferedLineData.isEmpty else { return }
        onOutput(
            ProcessOutputLine(
                stream: stream,
                text: String(decoding: bufferedLineData, as: UTF8.self)
                    .trimmingCharacters(in: .newlines)
            )
        )
    }
}

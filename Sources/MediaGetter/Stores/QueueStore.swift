import Foundation
import Observation

@MainActor
@Observable
final class QueueStore {
    typealias JobExecutor = @Sendable (JobRequest, @escaping @Sendable (JobEvent) async -> Void) async throws -> JobResult

    @ObservationIgnored
    private var executionTask: Task<Void, Never>?

    @ObservationIgnored
    private var executor: JobExecutor?

    var jobs: [JobRecord] = []
    var selectedJobID: UUID?
    var onCompleted: (@MainActor (JobRecord) -> Void)?

    func setExecutor(_ executor: @escaping JobExecutor) {
        self.executor = executor
        scheduleNextIfPossible()
    }

    func enqueue(_ request: JobRequest) {
        let record = JobRecord(
            id: request.id,
            request: request,
            status: .pending,
            stage: .queued,
            progress: 0,
            phase: "Waiting for queue",
            logs: [],
            artifacts: [],
            createdAt: Date(),
            startedAt: nil,
            completedAt: nil,
            errorMessage: nil
        )
        jobs.insert(record, at: 0)
        selectedJobID = record.id
        scheduleNextIfPossible()
    }

    func retry(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].status == .failed || jobs[index].status == .cancelled else { return }

        jobs[index].status = .pending
        jobs[index].stage = .queued
        jobs[index].progress = 0
        jobs[index].phase = "Waiting for queue"
        jobs[index].logs = []
        jobs[index].artifacts = []
        jobs[index].startedAt = nil
        jobs[index].completedAt = nil
        jobs[index].errorMessage = nil
        selectedJobID = jobs[index].id
        scheduleNextIfPossible()
    }

    func cancel(jobID: UUID) {
        if let index = jobs.firstIndex(where: { $0.id == jobID && $0.status == .pending }) {
            jobs[index].status = .cancelled
            jobs[index].stage = .cancelled
            jobs[index].phase = "Cancelled before start"
            jobs[index].completedAt = Date()
            return
        }

        guard let index = jobs.firstIndex(where: { $0.id == jobID && $0.status == .running }) else { return }
        let cancelledStageDescription = jobs[index].stage.cancelDescription
        jobs[index].status = .cancelling
        jobs[index].stage = .cancelling
        jobs[index].phase = "Cancelling \(cancelledStageDescription)"
        executionTask?.cancel()
    }

    var selectedJob: JobRecord? {
        guard let selectedJobID else { return nil }
        return jobs.first(where: { $0.id == selectedJobID })
    }

    var selectedRunningJob: JobRecord? {
        jobs.first(where: { $0.status == .running || $0.status == .cancelling })
    }

    private func scheduleNextIfPossible() {
        guard executionTask == nil, let executor else { return }
        guard let nextIndex = jobs.lastIndex(where: { $0.status == .pending }) else { return }

        jobs[nextIndex].status = .running
        jobs[nextIndex].phase = "Preparing job"
        jobs[nextIndex].startedAt = Date()
        let jobID = jobs[nextIndex].id
        let request = jobs[nextIndex].request

        executionTask = Task { [weak self] in
            guard let self else { return }

            do {
                let result = try await executor(request) { [weak self] event in
                    guard let self else { return }
                    await MainActor.run {
                        self.apply(event, to: jobID)
                    }
                }

                await MainActor.run {
                    self.finish(jobID: jobID, result: result)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.markCancelled(jobID: jobID)
                }
            } catch {
                await MainActor.run {
                    self.markFailed(jobID: jobID, error: error)
                }
            }

            await MainActor.run {
                self.executionTask = nil
                self.scheduleNextIfPossible()
            }
        }
    }

    private func apply(_ event: JobEvent, to jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }

        switch event {
        case .stage(let stage):
            jobs[index].stage = stage
        case .phase(let phase):
            jobs[index].phase = phase
        case .progress(let progress):
            jobs[index].progress = max(0, min(progress, 1))
        case .log(let log):
            jobs[index].logs.append(log)
        case .destination(let url):
            if let existingPrimaryIndex = jobs[index].artifacts.firstIndex(where: \.isPrimary) {
                jobs[index].artifacts[existingPrimaryIndex] = JobArtifact(kind: .media, url: url, isPrimary: true)
            } else {
                jobs[index].artifacts.append(JobArtifact(kind: .media, url: url, isPrimary: true))
            }
        case .artifact(let artifact):
            if let existingArtifactIndex = jobs[index].artifacts.firstIndex(where: { $0.path == artifact.path }) {
                jobs[index].artifacts[existingArtifactIndex] = artifact
            } else {
                jobs[index].artifacts.append(artifact)
            }
        }
    }

    private func finish(jobID: UUID, result: JobResult) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].status = .completed
        jobs[index].stage = .completed
        jobs[index].progress = 1
        jobs[index].phase = result.summary
        jobs[index].artifacts = result.artifacts
        jobs[index].completedAt = Date()
        onCompleted?(jobs[index])
    }

    private func markCancelled(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].status = .cancelled
        jobs[index].stage = .cancelled
        jobs[index].phase = "Cancelled"
        jobs[index].completedAt = Date()
    }

    private func markFailed(jobID: UUID, error: Error) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].status = .failed
        jobs[index].stage = .failed
        jobs[index].phase = "Failed"
        jobs[index].errorMessage = error.localizedDescription
        jobs[index].logs.append(error.localizedDescription)
        jobs[index].completedAt = Date()
    }
}

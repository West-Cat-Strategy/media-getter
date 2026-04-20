import Foundation
import Observation

@MainActor
@Observable
final class HistoryStore {
    @ObservationIgnored
    private let persistenceURL: URL

    var entries: [HistoryEntry]
    var selectedEntryID: UUID?

    init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL()
        self.entries = []
        load()
    }

    func record(job: JobRecord) {
        guard job.status == .completed else { return }

        let entry = HistoryEntry(
            id: job.id,
            jobKind: job.request.kind,
            title: job.request.title,
            subtitle: job.request.subtitle,
            source: job.request.source,
            outputPath: job.outputURL?.path,
            createdAt: job.completedAt ?? Date(),
            preset: job.request.preset,
            transcriptionOutputFormat: job.request.transcriptionOutputFormat,
            summary: job.phase
        )

        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > 50 {
            entries = Array(entries.prefix(50))
        }
        selectedEntryID = entry.id
        save()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else { return }

        do {
            let data = try Data(contentsOf: persistenceURL)
            entries = try JSONDecoder().decode([HistoryEntry].self, from: data)
            selectedEntryID = entries.first?.id
        } catch {
            entries = []
            selectedEntryID = nil
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            // Keep the UI responsive even if persistence fails.
        }
    }

    private static func defaultPersistenceURL() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return applicationSupport
            .appendingPathComponent("MediaGetter", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    var selectedEntry: HistoryEntry? {
        if let selectedEntryID {
            return entries.first(where: { $0.id == selectedEntryID }) ?? entries.first
        }

        return entries.first
    }
}

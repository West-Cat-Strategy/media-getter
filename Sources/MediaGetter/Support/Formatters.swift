import Foundation

enum Formatters {
    @MainActor
    private static var byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    @MainActor
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "Unknown size" }
        return byteFormatter.string(fromByteCount: value)
    }

    static func duration(_ value: TimeInterval?) -> String {
        guard let value else { return "Unknown duration" }
        let totalSeconds = max(0, Int(value.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }

    static func timecode(_ value: TimeInterval) -> String {
        let clamped = max(0, value)
        let totalSeconds = Int(clamped.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        let frames = Int(((clamped - floor(clamped)) * 30).rounded())
        return String(format: "%02d:%02d:%02d.%02d", hours, minutes, seconds, frames)
    }

    static func parseTimecode(_ input: String) -> TimeInterval? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawSeconds = Double(trimmed) {
            return rawSeconds
        }

        let pieces = trimmed.split(separator: ":").map(String.init)
        guard (2...3).contains(pieces.count) else { return nil }

        let secondsComponent = pieces.last?.split(separator: ".").map(String.init) ?? []
        guard let seconds = Double(secondsComponent.first ?? "") else { return nil }
        let fractionalFrames = Double(secondsComponent.dropFirst().first ?? "0") ?? 0
        let fractionalSeconds = fractionalFrames / 30.0

        let minutesIndex = pieces.count - 2
        guard let minutes = Double(pieces[minutesIndex]) else { return nil }
        let hours = pieces.count == 3 ? (Double(pieces[0]) ?? 0) : 0
        return (hours * 3600) + (minutes * 60) + seconds + fractionalSeconds
    }

    static func filenameStem(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}

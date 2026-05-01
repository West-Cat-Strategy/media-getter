import AppKit
import Foundation
import UniformTypeIdentifiers

enum FileHelpers {
    @MainActor
    static func chooseMediaFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .movie,
            .audio,
            UTType(filenameExtension: "mkv") ?? .data,
            UTType(filenameExtension: "webm") ?? .data
        ]
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func chooseFolder(startingAt startURL: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = startURL
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func chooseCookieFile(startingAt startURL: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = startURL
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func reveal(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor
    static func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

enum PasteboardHelper {
    @MainActor
    static func stringValue() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}

enum DropSupport {
    static let supportedTypeIdentifiers = [
        UTType.fileURL.identifier,
        UTType.url.identifier,
        UTType.text.identifier
    ]

    static func handleURLOrTextProviders(
        _ providers: [NSItemProvider],
        onFile: @escaping @MainActor (URL) -> Void,
        onText: @escaping @MainActor (String) -> Void
    ) -> Bool {
        handleURLOrTextProviders(
            providers,
            onFile: onFile,
            onRemoteURL: { onText($0.absoluteString) },
            onText: onText
        )
    }

    static func handleURLOrTextProviders(
        _ providers: [NSItemProvider],
        onFile: @escaping @MainActor (URL) -> Void,
        onRemoteURL: @escaping @MainActor (URL) -> Void,
        onText: @escaping @MainActor (String) -> Void
    ) -> Bool {
        var handledProvider = false

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handledProvider = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let url = url(from: item) else { return }
                    Task { @MainActor in
                        onFile(url)
                    }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                handledProvider = true
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    guard let url = url(from: item) else { return }
                    Task { @MainActor in
                        if url.isFileURL {
                            onFile(url)
                        } else {
                            onRemoteURL(url)
                        }
                    }
                }
                continue
            }

            if provider.canLoadObject(ofClass: NSString.self) {
                handledProvider = true
                _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                    guard let string = item as? String else { return }
                    Task { @MainActor in
                        onText(string)
                    }
                }
            }
        }

        return handledProvider
    }

    private static func url(from item: NSSecureCoding?) -> URL? {
        if let data = item as? Data,
           let string = String(data: data, encoding: .utf8) {
            return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let string = item as? String {
            return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return item as? URL
    }
}

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
    static func handleURLOrTextProviders(
        _ providers: [NSItemProvider],
        onFile: @escaping @MainActor (URL) -> Void,
        onText: @escaping @MainActor (String) -> Void
    ) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let loadedURL: URL?
                    if let data = item as? Data,
                       let string = String(data: data, encoding: .utf8) {
                        loadedURL = URL(string: string)
                    } else {
                        loadedURL = item as? URL
                    }

                    guard let url = loadedURL else { return }
                    Task { @MainActor in
                        onFile(url)
                    }
                }
                return true
            }

            if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                    guard let string = item as? String else { return }
                    Task { @MainActor in
                        onText(string)
                    }
                }
                return true
            }
        }

        return false
    }
}

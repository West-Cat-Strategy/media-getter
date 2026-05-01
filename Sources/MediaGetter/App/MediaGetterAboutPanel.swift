import AppKit

enum MediaGetterAboutPanel {
    static let westCatURL = URL(string: "https://westcat.ca")!
    static let githubURL = URL(string: "https://github.com/West-Cat-Strategy/media-getter")!
    static let ytDlpURL = URL(string: "https://github.com/yt-dlp/yt-dlp")!
    static let ffmpegURL = URL(string: "https://ffmpeg.org/")!

    @MainActor
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: options(icon: NSApp.applicationIconImage))
    }

    static func options(
        bundle: Bundle = .main,
        icon: NSImage? = nil
    ) -> [NSApplication.AboutPanelOptionKey: Any] {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: appName(from: bundle),
            .applicationVersion: marketingVersion(from: bundle),
            .version: buildVersion(from: bundle),
            .credits: credits()
        ]

        if let icon {
            options[.applicationIcon] = icon
        }

        return options
    }

    static func credits() -> NSAttributedString {
        let text = """
        Media-Getter is an open source project by West Cat Strategy (westcat.ca).

        Source code is available in the GitHub repository.

        Media-Getter bundles and acknowledges yt-dlp and ffmpeg for media discovery, download, and processing.
        """

        let bodyFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let linkColor = NSColor.linkColor
        let credits = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: bodyFont,
                .foregroundColor: NSColor.labelColor
            ]
        )

        addLink(to: credits, label: "West Cat Strategy", url: westCatURL, color: linkColor)
        addLink(to: credits, label: "westcat.ca", url: westCatURL, color: linkColor)
        addLink(to: credits, label: "GitHub repository", url: githubURL, color: linkColor)
        addLink(to: credits, label: "yt-dlp", url: ytDlpURL, color: linkColor)
        addLink(to: credits, label: "ffmpeg", url: ffmpegURL, color: linkColor)

        return credits
    }

    private static func appName(from bundle: Bundle) -> String {
        (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "MediaGetter"
    }

    private static func marketingVersion(from bundle: Bundle) -> String {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.1.0"
    }

    private static func buildVersion(from bundle: Bundle) -> String {
        (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? "1"
    }

    private static func addLink(
        to string: NSMutableAttributedString,
        label: String,
        url: URL,
        color: NSColor
    ) {
        let range = (string.string as NSString).range(of: label)
        guard range.location != NSNotFound else { return }

        string.addAttributes(
            [
                .link: url,
                .foregroundColor: color,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ],
            range: range
        )
    }
}

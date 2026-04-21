import Foundation

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum DownloadAuthStrategyKind: String, CaseIterable, Codable, Identifiable {
    case browser
    case cookieFile
    case advancedHeaders

    var id: Self { self }

    var title: String {
        switch self {
        case .browser:
            "Browser"
        case .cookieFile:
            "Cookie File"
        case .advancedHeaders:
            "Advanced Headers"
        }
    }

    var detail: String {
        switch self {
        case .browser:
            "Load cookies directly from a supported browser at download time."
        case .cookieFile:
            "Use an imported Netscape cookie file managed by the app."
        case .advancedHeaders:
            "Send a Cookie header plus optional User-Agent and extra headers."
        }
    }
}

enum DownloadCookieBrowser: String, CaseIterable, Codable, Identifiable {
    case brave
    case chrome
    case chromium
    case edge
    case firefox
    case opera
    case safari
    case vivaldi
    case whale

    var id: Self { self }

    var title: String {
        switch self {
        case .brave:
            "Brave"
        case .chrome:
            "Chrome"
        case .chromium:
            "Chromium"
        case .edge:
            "Microsoft Edge"
        case .firefox:
            "Firefox"
        case .opera:
            "Opera"
        case .safari:
            "Safari"
        case .vivaldi:
            "Vivaldi"
        case .whale:
            "Whale"
        }
    }
}

struct DownloadHeaderField: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = ""
    var value: String = ""

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isBlank: Bool {
        trimmedName.isEmpty && trimmedValue.isEmpty
    }
}

struct BrowserDownloadAuthConfiguration: Codable, Equatable {
    var browser: DownloadCookieBrowser
    var profile: String?
    var container: String?

    var ytDLPValue: String {
        var value = browser.rawValue

        if let profile {
            value += ":\(profile)"
        }

        if let container {
            value += "::\(container)"
        }

        return value
    }

    var summary: String {
        var components = [browser.title]

        if let profile {
            components.append("Profile \(profile)")
        }

        if let container {
            components.append("Container \(container)")
        }

        return components.joined(separator: " • ")
    }
}

struct CookieFileDownloadAuthConfiguration: Codable, Equatable {
    var managedCookieFilePath: String
}

struct AdvancedHeadersDownloadAuthConfiguration: Codable, Equatable {
    var secretReference: String
    var hasUserAgent: Bool
    var headerNames: [String]
}

enum DownloadAuthStrategy: Codable, Equatable {
    case browser(BrowserDownloadAuthConfiguration)
    case cookieFile(CookieFileDownloadAuthConfiguration)
    case advancedHeaders(AdvancedHeadersDownloadAuthConfiguration)

    private enum CodingKeys: String, CodingKey {
        case kind
        case browser
        case cookieFile
        case advancedHeaders
    }

    private enum Kind: String, Codable {
        case browser
        case cookieFile
        case advancedHeaders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .browser:
            self = .browser(try container.decode(BrowserDownloadAuthConfiguration.self, forKey: .browser))
        case .cookieFile:
            self = .cookieFile(try container.decode(CookieFileDownloadAuthConfiguration.self, forKey: .cookieFile))
        case .advancedHeaders:
            self = .advancedHeaders(try container.decode(AdvancedHeadersDownloadAuthConfiguration.self, forKey: .advancedHeaders))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .browser(let configuration):
            try container.encode(Kind.browser, forKey: .kind)
            try container.encode(configuration, forKey: .browser)
        case .cookieFile(let configuration):
            try container.encode(Kind.cookieFile, forKey: .kind)
            try container.encode(configuration, forKey: .cookieFile)
        case .advancedHeaders(let configuration):
            try container.encode(Kind.advancedHeaders, forKey: .kind)
            try container.encode(configuration, forKey: .advancedHeaders)
        }
    }

    var kind: DownloadAuthStrategyKind {
        switch self {
        case .browser:
            .browser
        case .cookieFile:
            .cookieFile
        case .advancedHeaders:
            .advancedHeaders
        }
    }
}

struct DownloadAuthProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var strategy: DownloadAuthStrategy

    var strategyTitle: String {
        strategy.kind.title
    }

    var summary: String {
        switch strategy {
        case .browser(let configuration):
            return configuration.summary
        case .cookieFile(let configuration):
            return URL(fileURLWithPath: configuration.managedCookieFilePath).lastPathComponent
        case .advancedHeaders(let configuration):
            var components = ["Cookie header"]

            if configuration.hasUserAgent {
                components.append("User-Agent")
            }

            if !configuration.headerNames.isEmpty {
                let count = configuration.headerNames.count
                components.append("\(count) custom header\(count == 1 ? "" : "s")")
            }

            return components.joined(separator: " • ")
        }
    }
}

enum ResolvedDownloadAuth: Equatable {
    case browser(BrowserDownloadAuthConfiguration)
    case cookieFile(path: String)
    case advancedHeaders(cookieHeader: String, userAgent: String?, headers: [DownloadHeaderField])
}

struct StoredAdvancedHeadersSecret: Codable, Equatable {
    var cookieHeader: String
    var userAgent: String?
    var customHeaders: [DownloadHeaderField]
}

struct DownloadAuthProfileDraft: Equatable {
    var profileID: UUID? = nil
    var name: String = ""
    var strategyKind: DownloadAuthStrategyKind = .browser
    var browser: DownloadCookieBrowser = .safari
    var browserProfile: String = ""
    var browserContainer: String = ""
    var selectedCookieFilePath: String = ""
    var managedCookieFilePath: String?
    var cookieHeader: String = ""
    var userAgent: String = ""
    var customHeaders: [DownloadHeaderField] = []
    var markAsDefault: Bool = false

    var trimmedName: String? {
        name.trimmedNonEmpty
    }

    var selectedCookieFileURL: URL? {
        selectedCookieFilePath.trimmedNonEmpty.map { URL(fileURLWithPath: $0) }
    }

    var trimmedBrowserProfile: String? {
        browserProfile.trimmedNonEmpty
    }

    var trimmedBrowserContainer: String? {
        browserContainer.trimmedNonEmpty
    }

    var trimmedCookieHeader: String? {
        cookieHeader.trimmedNonEmpty
    }

    var trimmedUserAgent: String? {
        userAgent.trimmedNonEmpty
    }

    var normalizedCustomHeaders: [DownloadHeaderField] {
        customHeaders.filter { !$0.isBlank }
    }
}

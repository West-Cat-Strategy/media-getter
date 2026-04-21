import Foundation
import Observation

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum AuthProfileStoreError: LocalizedError {
    case profileMissing
    case profileNameMissing
    case cookieFileMissing
    case cookieFileUnavailable(String)
    case cookieFileInvalid
    case cookieHeaderMissing
    case customHeaderIncomplete
    case customHeaderNameInvalid(String)
    case secretMissing

    var errorDescription: String? {
        switch self {
        case .profileMissing:
            return "That authentication profile is no longer available."
        case .profileNameMissing:
            return "Enter a name for this authentication profile."
        case .cookieFileMissing:
            return "Choose a Netscape cookie file before saving this profile."
        case .cookieFileUnavailable(let path):
            return "The saved cookie file is missing at \(path). Choose it again to continue."
        case .cookieFileInvalid:
            return "That file does not look like a Netscape cookie export."
        case .cookieHeaderMissing:
            return "Paste a Cookie header value before saving this profile."
        case .customHeaderIncomplete:
            return "Each custom header needs both a name and a value."
        case .customHeaderNameInvalid(let name):
            return "The custom header name '\(name)' is invalid."
        case .secretMissing:
            return "The secure headers for this authentication profile are no longer available."
        }
    }
}

@MainActor
@Observable
final class AuthProfileStore {
    @ObservationIgnored
    private let persistenceURL: URL

    @ObservationIgnored
    private let profilesDirectoryURL: URL

    @ObservationIgnored
    private let secretStore: SecretStore

    @ObservationIgnored
    private let fileManager: FileManager

    var profiles: [DownloadAuthProfile] = []
    var defaultProfileID: UUID?

    init(
        persistenceURL: URL? = nil,
        profilesDirectoryURL: URL? = nil,
        secretStore: SecretStore = KeychainSecretStore(),
        fileManager: FileManager = .default
    ) {
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL()
        self.profilesDirectoryURL = profilesDirectoryURL ?? Self.defaultProfilesDirectoryURL()
        self.secretStore = secretStore
        self.fileManager = fileManager
        load()
    }

    var defaultProfile: DownloadAuthProfile? {
        profile(for: defaultProfileID)
    }

    func profile(for id: UUID?) -> DownloadAuthProfile? {
        guard let id else { return nil }
        return profiles.first(where: { $0.id == id })
    }

    func setDefaultProfile(id: UUID?) {
        defaultProfileID = profiles.contains(where: { $0.id == id }) ? id : nil
        save()
    }

    func makeDraft(for profileID: UUID?) throws -> DownloadAuthProfileDraft {
        guard let profile = profile(for: profileID) else {
            return DownloadAuthProfileDraft(markAsDefault: false)
        }

        var draft = DownloadAuthProfileDraft(
            profileID: profile.id,
            name: profile.name,
            markAsDefault: defaultProfileID == profile.id
        )

        switch profile.strategy {
        case .browser(let configuration):
            draft.strategyKind = .browser
            draft.browser = configuration.browser
            draft.browserProfile = configuration.profile ?? ""
            draft.browserContainer = configuration.container ?? ""
        case .cookieFile(let configuration):
            draft.strategyKind = .cookieFile
            draft.selectedCookieFilePath = configuration.managedCookieFilePath
            draft.managedCookieFilePath = configuration.managedCookieFilePath
        case .advancedHeaders:
            draft.strategyKind = .advancedHeaders

            guard let secret = try secretStore.loadAdvancedHeadersSecret(for: secretReference(for: profile.id)) else {
                throw AuthProfileStoreError.secretMissing
            }

            draft.cookieHeader = secret.cookieHeader
            draft.userAgent = secret.userAgent ?? ""
            draft.customHeaders = secret.customHeaders
        }

        return draft
    }

    func resolvedAuth(for profileID: UUID) throws -> ResolvedDownloadAuth {
        guard let profile = profile(for: profileID) else {
            throw AuthProfileStoreError.profileMissing
        }

        switch profile.strategy {
        case .browser(let configuration):
            return .browser(configuration)
        case .cookieFile(let configuration):
            let url = URL(fileURLWithPath: configuration.managedCookieFilePath)
            try validateCookieFile(at: url)
            return .cookieFile(path: url.path)
        case .advancedHeaders:
            guard let secret = try secretStore.loadAdvancedHeadersSecret(for: secretReference(for: profileID)) else {
                throw AuthProfileStoreError.secretMissing
            }

            return .advancedHeaders(
                cookieHeader: try normalizedCookieHeader(from: secret.cookieHeader),
                userAgent: secret.userAgent?.trimmedNonEmpty,
                headers: try normalizedCustomHeaders(from: secret.customHeaders)
            )
        }
    }

    func resolvedAuth(for draft: DownloadAuthProfileDraft) throws -> ResolvedDownloadAuth {
        switch draft.strategyKind {
        case .browser:
            return .browser(
                BrowserDownloadAuthConfiguration(
                    browser: draft.browser,
                    profile: draft.trimmedBrowserProfile,
                    container: draft.browser == .firefox ? draft.trimmedBrowserContainer : nil
                )
            )
        case .cookieFile:
            let cookieURL: URL
            if let selectedCookieFileURL = draft.selectedCookieFileURL {
                cookieURL = selectedCookieFileURL
            } else if let managedCookieFilePath = draft.managedCookieFilePath {
                cookieURL = URL(fileURLWithPath: managedCookieFilePath)
            } else {
                throw AuthProfileStoreError.cookieFileMissing
            }

            try validateCookieFile(at: cookieURL)
            return .cookieFile(path: cookieURL.path)
        case .advancedHeaders:
            return .advancedHeaders(
                cookieHeader: try normalizedCookieHeader(from: draft.cookieHeader),
                userAgent: draft.trimmedUserAgent,
                headers: try normalizedCustomHeaders(from: draft.customHeaders)
            )
        }
    }

    @discardableResult
    func saveProfile(from draft: DownloadAuthProfileDraft) throws -> DownloadAuthProfile {
        guard let name = draft.trimmedName else {
            throw AuthProfileStoreError.profileNameMissing
        }

        let profileID = draft.profileID ?? UUID()
        let previousProfile = profile(for: profileID)
        let strategy: DownloadAuthStrategy

        switch draft.strategyKind {
        case .browser:
            strategy = .browser(
                BrowserDownloadAuthConfiguration(
                    browser: draft.browser,
                    profile: draft.trimmedBrowserProfile,
                    container: draft.browser == .firefox ? draft.trimmedBrowserContainer : nil
                )
            )
            try cleanupSensitiveResources(from: previousProfile, preserving: .browser)
        case .cookieFile:
            let managedCookieURL = try storeCookieFile(for: profileID, using: draft)
            strategy = .cookieFile(
                CookieFileDownloadAuthConfiguration(
                    managedCookieFilePath: managedCookieURL.path
                )
            )
            try cleanupSensitiveResources(from: previousProfile, preserving: .cookieFile)
        case .advancedHeaders:
            let secret = StoredAdvancedHeadersSecret(
                cookieHeader: try normalizedCookieHeader(from: draft.cookieHeader),
                userAgent: draft.trimmedUserAgent,
                customHeaders: try normalizedCustomHeaders(from: draft.customHeaders)
            )

            try secretStore.saveAdvancedHeadersSecret(secret, for: secretReference(for: profileID))
            strategy = .advancedHeaders(
                AdvancedHeadersDownloadAuthConfiguration(
                    secretReference: secretReference(for: profileID),
                    hasUserAgent: secret.userAgent != nil,
                    headerNames: secret.customHeaders.map(\.trimmedName)
                )
            )
            try cleanupSensitiveResources(from: previousProfile, preserving: .advancedHeaders)
        }

        let profile = DownloadAuthProfile(id: profileID, name: name, strategy: strategy)

        if let index = profiles.firstIndex(where: { $0.id == profileID }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }

        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if draft.markAsDefault {
            defaultProfileID = profile.id
        } else if defaultProfileID == profile.id {
            defaultProfileID = nil
        }

        save()
        return profile
    }

    func deleteProfile(id: UUID) throws {
        guard let existingProfile = profile(for: id) else { return }

        if defaultProfileID == id {
            defaultProfileID = nil
        }

        profiles.removeAll { $0.id == id }
        try cleanupSensitiveResources(from: existingProfile, preserving: nil)
        save()
    }

    func save() {
        normalizeDefaultSelection()

        do {
            try fileManager.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let data = try JSONEncoder().encode(Storage(defaultProfileID: defaultProfileID, profiles: profiles))
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            // Keep the UI responsive if persistence fails.
        }
    }

    func load() {
        guard fileManager.fileExists(atPath: persistenceURL.path) else { return }

        do {
            let data = try Data(contentsOf: persistenceURL)
            let storage = try JSONDecoder().decode(Storage.self, from: data)
            profiles = storage.profiles
            defaultProfileID = storage.defaultProfileID
            normalizeDefaultSelection()
        } catch {
            profiles = []
            defaultProfileID = nil
        }
    }

    private func cleanupSensitiveResources(
        from profile: DownloadAuthProfile?,
        preserving preservedKind: DownloadAuthStrategyKind?
    ) throws {
        guard let profile else { return }

        switch profile.strategy {
        case .browser:
            break
        case .cookieFile:
            guard preservedKind != .cookieFile else { return }
            let directoryURL = profilesDirectoryURL.appendingPathComponent(profile.id.uuidString, isDirectory: true)
            if fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.removeItem(at: directoryURL)
            }
        case .advancedHeaders:
            guard preservedKind != .advancedHeaders else { return }
            try secretStore.deleteSecret(for: secretReference(for: profile.id))
        }
    }

    private func normalizedCookieHeader(from rawValue: String) throws -> String {
        guard let cookieHeader = rawValue.trimmedNonEmpty else {
            throw AuthProfileStoreError.cookieHeaderMissing
        }

        return cookieHeader
    }

    private func normalizedCustomHeaders(from rawHeaders: [DownloadHeaderField]) throws -> [DownloadHeaderField] {
        try rawHeaders.compactMap { header in
            if header.isBlank {
                return nil
            }

            let name = header.trimmedName
            let value = header.trimmedValue

            guard !name.isEmpty, !value.isEmpty else {
                throw AuthProfileStoreError.customHeaderIncomplete
            }

            guard !name.contains(":") else {
                throw AuthProfileStoreError.customHeaderNameInvalid(name)
            }

            return DownloadHeaderField(id: header.id, name: name, value: value)
        }
    }

    private func storeCookieFile(for profileID: UUID, using draft: DownloadAuthProfileDraft) throws -> URL {
        let destinationDirectory = profilesDirectoryURL.appendingPathComponent(profileID.uuidString, isDirectory: true)
        let destinationURL = destinationDirectory.appendingPathComponent("cookies.txt")

        if let selectedCookieFileURL = draft.selectedCookieFileURL {
            try validateCookieFile(at: selectedCookieFileURL)
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            try fileManager.copyItem(at: selectedCookieFileURL, to: destinationURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
            return destinationURL
        }

        guard let managedCookieFilePath = draft.managedCookieFilePath else {
            throw AuthProfileStoreError.cookieFileMissing
        }

        let existingURL = URL(fileURLWithPath: managedCookieFilePath)
        try validateCookieFile(at: existingURL)
        return existingURL
    }

    private func validateCookieFile(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw AuthProfileStoreError.cookieFileUnavailable(url.path)
        }

        let data = try Data(contentsOf: url)
        let contents = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .ascii)
            ?? ""
        let lines = contents.split(whereSeparator: \.isNewline).map(String.init)

        let hasHeader = lines.first?.contains("Netscape HTTP Cookie File") == true
        let hasCookieRow = lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return false }
            return trimmed.split(separator: "\t").count >= 7
        }

        guard hasHeader || hasCookieRow else {
            throw AuthProfileStoreError.cookieFileInvalid
        }
    }

    private func normalizeDefaultSelection() {
        guard let defaultProfileID else { return }
        if !profiles.contains(where: { $0.id == defaultProfileID }) {
            self.defaultProfileID = nil
        }
    }

    private func secretReference(for profileID: UUID) -> String {
        profileID.uuidString
    }

    private static func defaultPersistenceURL() -> URL {
        defaultStorageRootURL().appendingPathComponent("auth_profiles.json")
    }

    private static func defaultProfilesDirectoryURL() -> URL {
        defaultStorageRootURL().appendingPathComponent("AuthProfiles", isDirectory: true)
    }

    private static func defaultStorageRootURL() -> URL {
        if ProcessInfo.processInfo.arguments.contains("-uitest-isolated-auth-store") {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("MediaGetterUITests", isDirectory: true)
                .appendingPathComponent("AuthStore", isDirectory: true)
        }

        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return applicationSupport.appendingPathComponent("MediaGetter", isDirectory: true)
    }
}

private struct Storage: Codable {
    var defaultProfileID: UUID?
    var profiles: [DownloadAuthProfile]
}

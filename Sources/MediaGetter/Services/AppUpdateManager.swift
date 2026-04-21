import AppKit
import Foundation
import Observation
import Sparkle

@MainActor
protocol AppUpdaterControlling: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var allowsAutomaticUpdates: Bool { get }

    func checkForUpdates()
    func installObservers(_ onChange: @escaping @MainActor () -> Void) -> [NSKeyValueObservation]
}

enum AppUpdatePhase: Equatable {
    case idle
    case checking
    case updateAvailable
    case downloading
    case extracting
    case readyToInstall
    case installing
    case upToDate
    case failed
}

struct AppUpdateRelease: Equatable {
    let displayVersion: String
    let buildVersion: String
    let downloadURL: URL?
    let infoURL: URL?
    let publishedAt: Date?
    let releaseNotes: String?
    let expectedContentLength: Int64?
    let minimumSystemVersion: String?
    let requiresAppleSilicon: Bool
    let supportsCurrentSystem: Bool

    init(item: SUAppcastItem) {
        self.displayVersion = item.displayVersionString
        self.buildVersion = item.versionString
        self.downloadURL = item.fileURL
        self.infoURL = item.infoURL
        self.publishedAt = item.date as Date?
        self.releaseNotes = Self.releaseNotes(from: item)
        self.expectedContentLength = item.contentLength > 0 ? Int64(clamping: item.contentLength) : nil
        self.minimumSystemVersion = item.minimumSystemVersion
        self.requiresAppleSilicon = item.hardwareRequirements.contains("arm64")
        self.supportsCurrentSystem = item.isMacOsUpdate
            && item.minimumOperatingSystemVersionIsOK
            && item.maximumOperatingSystemVersionIsOK
            && item.arm64HardwareRequirementIsOK
    }

    var versionDescription: String {
        if displayVersion == buildVersion {
            return "Version \(displayVersion)"
        }

        return "Version \(displayVersion) (\(buildVersion))"
    }

    var compatibilityDescription: String {
        var details: [String] = []

        if let minimumSystemVersion, !minimumSystemVersion.isEmpty {
            details.append("macOS \(minimumSystemVersion)+")
        }
        if requiresAppleSilicon {
            details.append("Apple Silicon")
        }

        return details.joined(separator: " • ")
    }

    private static func releaseNotes(from item: SUAppcastItem) -> String? {
        guard let rawNotes = item.itemDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawNotes.isEmpty else {
            return nil
        }

        if item.itemDescriptionFormat == "plain-text" {
            return rawNotes
        }

        guard let data = rawNotes.data(using: .utf8) else {
            return rawNotes
        }

        if let attributed = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ) {
            let flattened = attributed.string
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return flattened.isEmpty ? nil : flattened
        }

        let stripped = rawNotes
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }
}

private enum SparkleUpdateEvent {
    case userInitiatedCheckStarted(cancel: () -> Void)
    case updateFound(AppUpdateRelease, state: SPUUserUpdateState, reply: (SPUUserUpdateChoice) -> Void)
    case downloadStarted(cancel: () -> Void)
    case expectedContentLength(Int64)
    case downloadedBytes(Int64)
    case extractionStarted
    case extractionProgress(Double)
    case readyToInstall(reply: (SPUUserUpdateChoice) -> Void)
    case installing(applicationTerminated: Bool, retryTerminatingApplication: (() -> Void)?)
    case noUpdateFound(String)
    case failed(String)
    case cancelled
    case dismissed
}

@MainActor
final class SparkleAppUpdaterController: NSObject, AppUpdaterControlling {
    @ObservationIgnored
    private let updater: SPUUpdater

    @ObservationIgnored
    private let bridge: SparkleUpdateBridge

    @ObservationIgnored
    fileprivate var onEvent: ((SparkleUpdateEvent) -> Void)?

    init(startingUpdater: Bool, bundle: Bundle = .main) {
        self.bridge = SparkleUpdateBridge()
        self.updater = SPUUpdater(
            hostBundle: bundle,
            applicationBundle: bundle,
            userDriver: bridge,
            delegate: bridge
        )
        super.init()
        bridge.owner = self

        if startingUpdater {
            do {
                try updater.start()
            } catch {
                emit(.failed(error.localizedDescription))
            }
        }
    }

    var canCheckForUpdates: Bool {
        updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    var allowsAutomaticUpdates: Bool {
        updater.allowsAutomaticUpdates
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }

    func installObservers(_ onChange: @escaping @MainActor () -> Void) -> [NSKeyValueObservation] {
        [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { _, _ in
                Task { @MainActor in
                    onChange()
                }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { _, _ in
                Task { @MainActor in
                    onChange()
                }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { _, _ in
                Task { @MainActor in
                    onChange()
                }
            },
            updater.observe(\.allowsAutomaticUpdates, options: [.initial, .new]) { _, _ in
                Task { @MainActor in
                    onChange()
                }
            }
        ]
    }

    fileprivate func emit(_ event: SparkleUpdateEvent) {
        onEvent?(event)
    }
}

@MainActor
private final class SparkleUpdateBridge: NSObject, SPUUpdaterDelegate, SPUUserDriver {
    weak var owner: SparkleAppUpdaterController?

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        let automaticDownloading: NSNumber?
        if owner?.allowsAutomaticUpdates == true {
            automaticDownloading = NSNumber(value: owner?.automaticallyDownloadsUpdates ?? false)
        } else {
            automaticDownloading = nil
        }

        reply(
            SUUpdatePermissionResponse(
                automaticUpdateChecks: owner?.automaticallyChecksForUpdates ?? true,
                automaticUpdateDownloading: automaticDownloading,
                sendSystemProfile: false
            )
        )
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        owner?.emit(.userInitiatedCheckStarted(cancel: cancellation))
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        owner?.emit(.updateFound(AppUpdateRelease(item: appcastItem), state: state, reply: reply))
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // Embedded release notes are surfaced from the appcast item in Settings.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        owner?.emit(.failed(error.localizedDescription))
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        owner?.emit(.noUpdateFound(error.localizedDescription))
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        owner?.emit(.failed(error.localizedDescription))
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        owner?.emit(.downloadStarted(cancel: cancellation))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        owner?.emit(.expectedContentLength(Int64(clamping: expectedContentLength)))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        owner?.emit(.downloadedBytes(Int64(clamping: length)))
    }

    func showDownloadDidStartExtractingUpdate() {
        owner?.emit(.extractionStarted)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        owner?.emit(.extractionProgress(progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        owner?.emit(.readyToInstall(reply: reply))
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        owner?.emit(.installing(applicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication))
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        owner?.emit(.dismissed)
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        owner?.emit(.cancelled)
    }
}

@MainActor
@Observable
final class AppUpdateManager {
    let isUpdaterEnabled: Bool
    private(set) var canCheckForUpdates: Bool
    private(set) var allowsAutomaticUpdates: Bool
    let currentVersionString: String
    let currentBuildString: String

    private(set) var updatePhase: AppUpdatePhase
    private(set) var updateStatusTitle: String
    private(set) var updateStatusDetail: String
    private(set) var availableUpdate: AppUpdateRelease?
    private(set) var expectedDownloadBytes: Int64?
    private(set) var downloadedBytes: Int64
    private(set) var extractionProgress: Double

    private var automaticallyChecksForUpdatesStorage: Bool
    private var automaticallyDownloadsUpdatesStorage: Bool

    var automaticallyChecksForUpdates: Bool {
        get { automaticallyChecksForUpdatesStorage }
        set {
            guard automaticallyChecksForUpdatesStorage != newValue else { return }
            guard let updater else { return }
            automaticallyChecksForUpdatesStorage = newValue
            if updater.automaticallyChecksForUpdates != newValue {
                updater.automaticallyChecksForUpdates = newValue
            }
            synchronizeFromUpdater()
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { automaticallyDownloadsUpdatesStorage }
        set {
            guard automaticallyDownloadsUpdatesStorage != newValue else { return }
            guard let updater else { return }
            automaticallyDownloadsUpdatesStorage = newValue
            if updater.automaticallyDownloadsUpdates != newValue {
                updater.automaticallyDownloadsUpdates = newValue
            }
            synchronizeFromUpdater()
        }
    }

    var canConfigureAutomaticUpdateChecks: Bool { isUpdaterEnabled }
    var canConfigureAutomaticDownloads: Bool {
        isUpdaterEnabled && automaticallyChecksForUpdates && allowsAutomaticUpdates
    }
    var updatesUnavailableMessage: String? {
        guard !isUpdaterEnabled else { return nil }
        return "Updates are only available in release builds."
    }

    var downloadProgress: Double? {
        guard updatePhase == .downloading,
              let expectedDownloadBytes,
              expectedDownloadBytes > 0 else {
            return nil
        }

        return min(1, Double(downloadedBytes) / Double(expectedDownloadBytes))
    }

    var extractionProgressLabel: String {
        "\(Int((max(0, min(1, extractionProgress)) * 100).rounded()))% complete"
    }

    var transferProgressLabel: String? {
        guard updatePhase == .downloading else { return nil }

        let received = Formatters.bytes(downloadedBytes)
        guard let expectedDownloadBytes, expectedDownloadBytes > 0 else {
            return received
        }

        return "\(received) of \(Formatters.bytes(expectedDownloadBytes))"
    }

    var primaryUpdateActionTitle: String {
        if pendingReadyToInstallReply != nil {
            return "Install and Relaunch"
        }

        if pendingDownloadDecisionReply != nil {
            return "Download Update"
        }

        return "Check for Updates..."
    }

    var canPerformPrimaryUpdateAction: Bool {
        if pendingReadyToInstallReply != nil || pendingDownloadDecisionReply != nil {
            return true
        }

        return canCheckForUpdates
    }

    var dismissPendingUpdateTitle: String? {
        if pendingReadyToInstallReply != nil {
            return "Not Now"
        }

        if pendingDownloadDecisionReply != nil {
            return "Later"
        }

        return nil
    }

    var canDismissPendingUpdate: Bool {
        pendingReadyToInstallReply != nil || pendingDownloadDecisionReply != nil
    }

    var canSkipPendingUpdate: Bool {
        pendingReadyToInstallReply != nil || pendingDownloadDecisionReply != nil
    }

    var canCancelUpdateSession: Bool {
        pendingCancellation != nil
    }

    @ObservationIgnored
    private let updater: (any AppUpdaterControlling)?

    @ObservationIgnored
    private var updaterObservations: [NSKeyValueObservation] = []

    @ObservationIgnored
    private var pendingDownloadDecisionReply: ((SPUUserUpdateChoice) -> Void)?

    @ObservationIgnored
    private var pendingReadyToInstallReply: ((SPUUserUpdateChoice) -> Void)?

    @ObservationIgnored
    private var pendingCancellation: (() -> Void)?

    init(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo,
        updater: (any AppUpdaterControlling)? = nil,
        updaterEnabledOverride: Bool? = nil
    ) {
        let isUpdaterEnabled = updaterEnabledOverride ?? Self.updaterEnabled(from: bundle)
        let initialTitle = isUpdaterEnabled ? "No update activity yet" : "Updates unavailable"
        let initialDetail = isUpdaterEnabled
            ? "Checks use the GitHub release feed and wait until the update is ready before asking to install."
            : "Updates are only available in release builds."

        self.isUpdaterEnabled = isUpdaterEnabled
        self.currentVersionString = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        self.currentBuildString = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        self.updatePhase = .idle
        self.updateStatusTitle = initialTitle
        self.updateStatusDetail = initialDetail
        self.availableUpdate = nil
        self.expectedDownloadBytes = nil
        self.downloadedBytes = 0
        self.extractionProgress = 0

        let sparkleUpdater: SparkleAppUpdaterController?

        if isUpdaterEnabled {
            let shouldStartUpdater = processInfo.environment["XCTestConfigurationFilePath"] == nil
            let resolvedSparkleUpdater = updater as? SparkleAppUpdaterController
            sparkleUpdater = resolvedSparkleUpdater ?? (updater == nil ? SparkleAppUpdaterController(startingUpdater: shouldStartUpdater, bundle: bundle) : nil)
            let resolvedUpdater = updater ?? sparkleUpdater
            self.updater = resolvedUpdater
            self.canCheckForUpdates = resolvedUpdater?.canCheckForUpdates ?? false
            self.automaticallyChecksForUpdatesStorage = resolvedUpdater?.automaticallyChecksForUpdates ?? false
            self.automaticallyDownloadsUpdatesStorage = resolvedUpdater?.automaticallyDownloadsUpdates ?? false
            self.allowsAutomaticUpdates = resolvedUpdater?.allowsAutomaticUpdates ?? false
        } else {
            sparkleUpdater = nil
            self.updater = nil
            self.canCheckForUpdates = false
            self.automaticallyChecksForUpdatesStorage = false
            self.automaticallyDownloadsUpdatesStorage = false
            self.allowsAutomaticUpdates = false
        }

        installObservers()
        synchronizeFromUpdater()

        sparkleUpdater?.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    var versionDescription: String {
        if currentBuildString == currentVersionString {
            return "Version \(currentVersionString)"
        }

        return "Version \(currentVersionString) (\(currentBuildString))"
    }

    func checkForUpdates() {
        guard isUpdaterEnabled else { return }
        openSettingsWindowIfPossible()
        updater?.checkForUpdates()
    }

    func performPrimaryUpdateAction() {
        if let pendingReadyToInstallReply {
            self.pendingReadyToInstallReply = nil
            setInstallingStatus()
            pendingReadyToInstallReply(.install)
            return
        }

        if let pendingDownloadDecisionReply {
            self.pendingDownloadDecisionReply = nil
            setDownloadingStatus(preparing: true)
            pendingDownloadDecisionReply(.install)
            return
        }

        checkForUpdates()
    }

    func dismissPendingUpdate() {
        if let pendingReadyToInstallReply {
            self.pendingReadyToInstallReply = nil
            pendingReadyToInstallReply(.dismiss)
            setIdleStatus(detail: "The verified update stays available and can be offered again later.")
            return
        }

        if let pendingDownloadDecisionReply {
            self.pendingDownloadDecisionReply = nil
            pendingDownloadDecisionReply(.dismiss)
            setIdleStatus(detail: "The available release was dismissed for now.")
        }
    }

    func skipPendingUpdate() {
        if let pendingReadyToInstallReply {
            self.pendingReadyToInstallReply = nil
            pendingReadyToInstallReply(.skip)
            setIdleStatus(detail: "That release has been skipped.")
            return
        }

        if let pendingDownloadDecisionReply {
            self.pendingDownloadDecisionReply = nil
            pendingDownloadDecisionReply(.skip)
            setIdleStatus(detail: "That release has been skipped.")
        }
    }

    func cancelUpdateSession() {
        guard let pendingCancellation else { return }
        self.pendingCancellation = nil
        pendingCancellation()
        setIdleStatus(detail: "The update operation was cancelled.")
    }

    private func installObservers() {
        guard let updater else { return }
        updaterObservations = updater.installObservers { [weak self] in
            self?.synchronizeFromUpdater()
        }
    }

    private func synchronizeFromUpdater() {
        guard let updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdatesStorage = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdatesStorage = updater.automaticallyDownloadsUpdates
        allowsAutomaticUpdates = updater.allowsAutomaticUpdates
    }

    private func handle(_ event: SparkleUpdateEvent) {
        switch event {
        case .userInitiatedCheckStarted(let cancel):
            resetProgress()
            availableUpdate = nil
            pendingCancellation = cancel
            updatePhase = .checking
            updateStatusTitle = "Checking GitHub release feed"
            updateStatusDetail = "Looking for the latest compatible macOS release."

        case .updateFound(let release, let state, let reply):
            availableUpdate = release
            pendingCancellation = nil
            resetProgress()

            switch state.stage {
            case .notDownloaded:
                if state.userInitiated || automaticallyDownloadsUpdates {
                    setDownloadingStatus(preparing: true)
                    reply(.install)
                } else {
                    pendingDownloadDecisionReply = reply
                    updatePhase = .updateAvailable
                    updateStatusTitle = "Update \(release.displayVersion) is available"
                    updateStatusDetail = "A compatible release is ready to download when you are."
                }

            case .downloaded:
                pendingReadyToInstallReply = reply
                updatePhase = .readyToInstall
                updateStatusTitle = "Update \(release.displayVersion) is ready"
                updateStatusDetail = "The downloaded release is verified and ready to install."

            case .installing:
                setInstallingStatus()
                reply(.install)

            @unknown default:
                pendingDownloadDecisionReply = reply
                updatePhase = .updateAvailable
                updateStatusTitle = "Update \(release.displayVersion) is available"
                updateStatusDetail = "A compatible release is available, but its state is newer than this build knows about."
            }

        case .downloadStarted(let cancel):
            pendingCancellation = cancel
            pendingDownloadDecisionReply = nil
            setDownloadingStatus(preparing: false)

        case .expectedContentLength(let contentLength):
            expectedDownloadBytes = contentLength > 0 ? contentLength : nil
            if let transferProgressLabel {
                updateStatusDetail = transferProgressLabel
            }

        case .downloadedBytes(let byteCount):
            downloadedBytes += max(0, byteCount)
            if let transferProgressLabel {
                updateStatusDetail = transferProgressLabel
            }

        case .extractionStarted:
            pendingCancellation = nil
            updatePhase = .extracting
            extractionProgress = 0
            updateStatusTitle = "Verifying update archive"
            updateStatusDetail = "Confirming the signed download and preparing installation."

        case .extractionProgress(let progress):
            extractionProgress = max(0, min(1, progress))
            updateStatusDetail = extractionProgressLabel

        case .readyToInstall(let reply):
            pendingReadyToInstallReply = reply
            pendingCancellation = nil
            updatePhase = .readyToInstall
            updateStatusTitle = "Update is ready to install"
            updateStatusDetail = "Installation permission is only needed now that the verified update is ready."

        case .installing(let applicationTerminated, _):
            setInstallingStatus()
            if !applicationTerminated {
                updateStatusDetail = "MediaGetter will relaunch after it closes."
            }

        case .noUpdateFound(let message):
            clearPendingActions()
            updatePhase = .upToDate
            updateStatusTitle = "You're up to date"
            updateStatusDetail = message

        case .failed(let message):
            clearPendingActions()
            updatePhase = .failed
            updateStatusTitle = "Update failed"
            updateStatusDetail = message

        case .cancelled:
            clearPendingActions()
            setIdleStatus(detail: "The update download was cancelled.")

        case .dismissed:
            clearPendingActions()
        }
    }

    private func setDownloadingStatus(preparing: Bool) {
        resetProgress()
        updatePhase = .downloading
        updateStatusTitle = preparing ? "Preparing secure download" : "Downloading update"
        updateStatusDetail = preparing
            ? "The latest compatible release was found. Starting a verified download."
            : "Fetching the release archive from GitHub."
    }

    private func setInstallingStatus() {
        pendingReadyToInstallReply = nil
        pendingCancellation = nil
        updatePhase = .installing
        updateStatusTitle = "Installing update"
        updateStatusDetail = "Applying the verified release and preparing relaunch."
    }

    private func setIdleStatus(detail: String) {
        resetProgress()
        updatePhase = .idle
        updateStatusTitle = "Update session finished"
        updateStatusDetail = detail
    }

    private func clearPendingActions() {
        pendingCancellation = nil
        pendingDownloadDecisionReply = nil
        pendingReadyToInstallReply = nil
        resetProgress()
    }

    private func resetProgress() {
        expectedDownloadBytes = nil
        downloadedBytes = 0
        extractionProgress = 0
    }

    private func openSettingsWindowIfPossible() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private static func updaterEnabled(from bundle: Bundle) -> Bool {
        let key = "MGUpdaterEnabled"

        if let boolValue = bundle.object(forInfoDictionaryKey: key) as? Bool {
            return boolValue
        }

        if let stringValue = bundle.object(forInfoDictionaryKey: key) as? String {
            return NSString(string: stringValue).boolValue
        }

        if let numberValue = bundle.object(forInfoDictionaryKey: key) as? NSNumber {
            return numberValue.boolValue
        }

        return false
    }
}

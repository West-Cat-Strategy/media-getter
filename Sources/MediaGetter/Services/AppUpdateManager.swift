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

@MainActor
final class SparkleAppUpdaterController: AppUpdaterControlling {
    @ObservationIgnored
    private let updaterController: SPUStandardUpdaterController

    init(startingUpdater: Bool) {
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updaterController.updater.automaticallyDownloadsUpdates }
        set { updaterController.updater.automaticallyDownloadsUpdates = newValue }
    }

    var allowsAutomaticUpdates: Bool {
        updaterController.updater.allowsAutomaticUpdates
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    func installObservers(_ onChange: @escaping @MainActor () -> Void) -> [NSKeyValueObservation] {
        let updater = updaterController.updater
        return [
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
}

@MainActor
@Observable
final class AppUpdateManager {
    let isUpdaterEnabled: Bool
    private(set) var canCheckForUpdates: Bool
    private(set) var allowsAutomaticUpdates: Bool
    let currentVersionString: String
    let currentBuildString: String

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

    @ObservationIgnored
    private let updater: (any AppUpdaterControlling)?

    @ObservationIgnored
    private var updaterObservations: [NSKeyValueObservation] = []

    init(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo,
        updater: (any AppUpdaterControlling)? = nil,
        updaterEnabledOverride: Bool? = nil
    ) {
        let isUpdaterEnabled = updaterEnabledOverride ?? Self.updaterEnabled(from: bundle)
        self.isUpdaterEnabled = isUpdaterEnabled
        self.currentVersionString = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        self.currentBuildString = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

        if isUpdaterEnabled {
            let shouldStartUpdater = processInfo.environment["XCTestConfigurationFilePath"] == nil
            let resolvedUpdater = updater ?? SparkleAppUpdaterController(startingUpdater: shouldStartUpdater)
            self.updater = resolvedUpdater
            self.canCheckForUpdates = resolvedUpdater.canCheckForUpdates
            self.automaticallyChecksForUpdatesStorage = resolvedUpdater.automaticallyChecksForUpdates
            self.automaticallyDownloadsUpdatesStorage = resolvedUpdater.automaticallyDownloadsUpdates
            self.allowsAutomaticUpdates = resolvedUpdater.allowsAutomaticUpdates
        } else {
            self.updater = nil
            self.canCheckForUpdates = false
            self.automaticallyChecksForUpdatesStorage = false
            self.automaticallyDownloadsUpdatesStorage = false
            self.allowsAutomaticUpdates = false
        }

        installObservers()
        synchronizeFromUpdater()
    }

    var versionDescription: String {
        if currentBuildString == currentVersionString {
            return "Version \(currentVersionString)"
        }

        return "Version \(currentVersionString) (\(currentBuildString))"
    }

    func checkForUpdates() {
        updater?.checkForUpdates()
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

import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class AppUpdateManager {
    private(set) var canCheckForUpdates: Bool

    var automaticallyChecksForUpdates: Bool {
        didSet {
            guard !isSynchronizingWithUpdater else { return }
            guard automaticallyChecksForUpdates != updaterController.updater.automaticallyChecksForUpdates else { return }
            updaterController.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            synchronizeFromUpdater()
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        didSet {
            guard !isSynchronizingWithUpdater else { return }
            guard automaticallyDownloadsUpdates != updaterController.updater.automaticallyDownloadsUpdates else { return }
            updaterController.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
            synchronizeFromUpdater()
        }
    }

    private(set) var allowsAutomaticUpdates: Bool
    let currentVersionString: String
    let currentBuildString: String

    @ObservationIgnored
    private let updaterController: SPUStandardUpdaterController

    @ObservationIgnored
    private var updaterObservations: [NSKeyValueObservation] = []

    @ObservationIgnored
    private var isSynchronizingWithUpdater = false

    init(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo,
        updaterController: SPUStandardUpdaterController? = nil
    ) {
        let shouldStartUpdater = processInfo.environment["XCTestConfigurationFilePath"] == nil
        let controller = updaterController
            ?? SPUStandardUpdaterController(startingUpdater: shouldStartUpdater, updaterDelegate: nil, userDriverDelegate: nil)
        self.updaterController = controller
        self.canCheckForUpdates = controller.updater.canCheckForUpdates
        self.automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates
        self.allowsAutomaticUpdates = controller.updater.allowsAutomaticUpdates
        self.currentVersionString = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        self.currentBuildString = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

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
        updaterController.checkForUpdates(nil)
    }

    private func installObservers() {
        let updater = updaterController.updater
        updaterObservations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.synchronizeFromUpdater()
                }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.synchronizeFromUpdater()
                }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.synchronizeFromUpdater()
                }
            },
            updater.observe(\.allowsAutomaticUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.synchronizeFromUpdater()
                }
            }
        ]
    }

    private func synchronizeFromUpdater() {
        isSynchronizingWithUpdater = true
        canCheckForUpdates = updaterController.updater.canCheckForUpdates
        automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updaterController.updater.automaticallyDownloadsUpdates
        allowsAutomaticUpdates = updaterController.updater.allowsAutomaticUpdates
        isSynchronizingWithUpdater = false
    }
}

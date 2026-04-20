import Foundation
import Observation

@MainActor
@Observable
final class PreferencesStore {
    @ObservationIgnored
    private let defaults: UserDefaults

    var defaultDownloadFolderPath: String {
        didSet { defaults.set(defaultDownloadFolderPath, forKey: Keys.defaultDownloadFolderPath) }
    }

    var overwriteExisting: Bool {
        didSet { defaults.set(overwriteExisting, forKey: Keys.overwriteExisting) }
    }

    var filenameTemplate: String {
        didSet { defaults.set(filenameTemplate, forKey: Keys.filenameTemplate) }
    }

    var defaultDownloadPreset: OutputPresetID {
        didSet { defaults.set(defaultDownloadPreset.rawValue, forKey: Keys.defaultDownloadPreset) }
    }

    var defaultConvertPreset: OutputPresetID {
        didSet { defaults.set(defaultConvertPreset.rawValue, forKey: Keys.defaultConvertPreset) }
    }

    var defaultDownloadSubtitlePolicy: SubtitleSourcePolicy {
        didSet { defaults.set(defaultDownloadSubtitlePolicy.rawValue, forKey: Keys.defaultDownloadSubtitlePolicy) }
    }

    var defaultConvertAutoSubtitles: Bool {
        didSet { defaults.set(defaultConvertAutoSubtitles, forKey: Keys.defaultConvertAutoSubtitles) }
    }

    var defaultTrimAutoSubtitles: Bool {
        didSet { defaults.set(defaultTrimAutoSubtitles, forKey: Keys.defaultTrimAutoSubtitles) }
    }

    var defaultSubtitleOutputFormat: TranscriptionOutputFormat {
        didSet { defaults.set(defaultSubtitleOutputFormat.rawValue, forKey: Keys.defaultSubtitleOutputFormat) }
    }

    var hardwareAcceleration: HardwareAccelerationMode {
        didSet { defaults.set(hardwareAcceleration.rawValue, forKey: Keys.hardwareAcceleration) }
    }

    var allowFastTrimCopy: Bool {
        didSet { defaults.set(allowFastTrimCopy, forKey: Keys.allowFastTrimCopy) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        self.defaultDownloadFolderPath = defaults.string(forKey: Keys.defaultDownloadFolderPath)
            ?? downloadsURL?.path
            ?? NSHomeDirectory()
        self.overwriteExisting = defaults.object(forKey: Keys.overwriteExisting) as? Bool ?? true
        self.filenameTemplate = defaults.string(forKey: Keys.filenameTemplate) ?? "%(title)s"
        self.defaultDownloadPreset = OutputPresetID(rawValue: defaults.string(forKey: Keys.defaultDownloadPreset) ?? "") ?? .mp4Video
        self.defaultConvertPreset = OutputPresetID(rawValue: defaults.string(forKey: Keys.defaultConvertPreset) ?? "") ?? .mp4Video
        self.defaultDownloadSubtitlePolicy = SubtitleSourcePolicy(
            rawValue: defaults.string(forKey: Keys.defaultDownloadSubtitlePolicy) ?? ""
        ) ?? .preferSourceThenGenerate
        self.defaultConvertAutoSubtitles = defaults.object(forKey: Keys.defaultConvertAutoSubtitles) as? Bool ?? false
        self.defaultTrimAutoSubtitles = defaults.object(forKey: Keys.defaultTrimAutoSubtitles) as? Bool ?? false
        self.defaultSubtitleOutputFormat = TranscriptionOutputFormat(
            rawValue: defaults.string(forKey: Keys.defaultSubtitleOutputFormat) ?? ""
        ) ?? .srt
        self.hardwareAcceleration = HardwareAccelerationMode(rawValue: defaults.string(forKey: Keys.hardwareAcceleration) ?? "") ?? .automatic
        self.allowFastTrimCopy = defaults.object(forKey: Keys.allowFastTrimCopy) as? Bool ?? true
    }

    var defaultDownloadFolderURL: URL {
        URL(fileURLWithPath: defaultDownloadFolderPath, isDirectory: true)
    }

    private enum Keys {
        static let defaultDownloadFolderPath = "preferences.defaultDownloadFolderPath"
        static let overwriteExisting = "preferences.overwriteExisting"
        static let filenameTemplate = "preferences.filenameTemplate"
        static let defaultDownloadPreset = "preferences.defaultDownloadPreset"
        static let defaultConvertPreset = "preferences.defaultConvertPreset"
        static let defaultDownloadSubtitlePolicy = "preferences.defaultDownloadSubtitlePolicy"
        static let defaultConvertAutoSubtitles = "preferences.defaultConvertAutoSubtitles"
        static let defaultTrimAutoSubtitles = "preferences.defaultTrimAutoSubtitles"
        static let defaultSubtitleOutputFormat = "preferences.defaultSubtitleOutputFormat"
        static let hardwareAcceleration = "preferences.hardwareAcceleration"
        static let allowFastTrimCopy = "preferences.allowFastTrimCopy"
    }
}

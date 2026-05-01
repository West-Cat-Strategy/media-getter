import XCTest

@MainActor
final class MediaGetterUITests: XCTestCase {
    private enum IDs {
        static let downloadAuthPicker = "download-auth-picker"
        static let downloadConfigureAuthButton = "download-configure-auth-button"
        static let downloadAuthSummary = "download-auth-summary"
        static let downloadURLField = "download-url-field"
        static let downloadInspectButton = "download-inspect-button"
        static let downloadQueueButton = "download-queue-button"
        static let downloadSubtitlePolicyPicker = "download-subtitle-policy-picker"
        static let downloadInlineStatusTitle = "download-inline-status-title"
        static let downloadInlineStatusMessage = "download-inline-status-message"
        static let downloadInlineProgress = "download-inline-progress"
        static let downloadInlineOpenQueueButton = "download-inline-open-queue-button"
        static let downloadInlineCancelButton = "download-inline-cancel-button"
        static let authSheetProfilePicker = "auth-sheet-profile-picker"
        static let authSheetStepPicker = "auth-sheet-step-picker"
        static let authSheetStrategyPicker = "auth-sheet-strategy-picker"
        static let convertSubtitleToggle = "convert-subtitle-toggle"
        static let trimOpenButton = "trim-open-button"
        static let trimSubtitleToggle = "trim-subtitle-toggle"
        static let sidebarConvert = "sidebar-convert"
        static let sidebarTrim = "sidebar-trim"
        static let transcribeOpenButton = "transcribe-open-button"
        static let transcribeQueueButton = "transcribe-queue-button"
        static let transcribeFormatPicker = "transcribe-format-picker"
        static let queueJobCancelButton = "queue-job-cancel-button"
        static let queueJobRetryButton = "queue-job-retry-button"
        static let settingsOverwriteToggle = "settings-overwrite-toggle"
    }

    func testPrimaryToolbarButtonsAppear() {
        let app = makeApp()
        app.launch()

        let pasteURL = app.buttons["Paste URL"].waitForExistence(timeout: 5)
        let openFile = app.buttons["Open File"].exists
        let start = app.buttons["Start"].exists
        let cancel = app.buttons["Cancel"].exists
        let reveal = app.buttons["Reveal"].exists

        XCTAssertTrue(pasteURL)
        XCTAssertTrue(openFile)
        XCTAssertTrue(start)
        XCTAssertTrue(cancel)
        XCTAssertTrue(reveal)
    }

    func testDownloadWorkspaceShowsPrimaryControls() {
        let app = makeApp()
        app.launch()

        let urlFieldExists = app.textFields[IDs.downloadURLField].waitForExistence(timeout: 5)
        let inspectButtonExists = app.buttons[IDs.downloadInspectButton].exists

        XCTAssertTrue(urlFieldExists)
        XCTAssertTrue(inspectButtonExists)
    }

    func testCompactWindowKeepsDownloadControlsReachable() {
        let app = makeCompactApp()
        app.launch()

        XCTAssertTrue(app.textFields[IDs.downloadURLField].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[IDs.downloadInspectButton].exists)
        XCTAssertTrue(app.buttons[IDs.downloadConfigureAuthButton].exists)
    }

    func testDownloadOptionsResetWhenURLChangesAfterInspection() {
        let app = makeApp()
        app.launchArguments.append("-uitest-seed-subtitle-workspaces")
        app.launch()

        let urlField = app.textFields[IDs.downloadURLField]
        XCTAssertTrue(urlField.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[IDs.downloadQueueButton].exists)

        urlField.click()
        app.typeKey("a", modifierFlags: .command)
        urlField.typeText("https://example.com/changed")

        XCTAssertFalse(app.buttons[IDs.downloadQueueButton].waitForExistence(timeout: 1.5))
    }

    func testDownloadInlineProbeStatusAppearsWhenSeeded() {
        let app = makeApp()
        app.launchArguments.append("-uitest-seed-download-probe-progress")
        app.launch()

        let inlineStatusTitle = app.staticTexts[IDs.downloadInlineStatusTitle]
        XCTAssertTrue(inlineStatusTitle.waitForExistence(timeout: 5))
        XCTAssertTrue((inlineStatusTitle.value as? String)?.contains("Inspecting URL") == true)
        XCTAssertTrue(app.staticTexts[IDs.downloadInlineStatusMessage].exists)
        XCTAssertTrue(hasInlineProgressIndicator(in: app))
    }

    func testDownloadInlineRunningProgressAppearsWhenSeeded() {
        let app = makeApp()
        app.launchArguments.append("-uitest-seed-running-download")
        app.launch()

        let inlineStatusTitle = app.staticTexts[IDs.downloadInlineStatusTitle]
        XCTAssertTrue(inlineStatusTitle.waitForExistence(timeout: 5))
        XCTAssertTrue((inlineStatusTitle.value as? String)?.contains("Download in progress") == true)
        XCTAssertTrue(app.staticTexts[IDs.downloadInlineStatusMessage].exists)
        XCTAssertTrue(app.progressIndicators[IDs.downloadInlineProgress].exists)
        XCTAssertTrue(app.buttons[IDs.downloadInlineOpenQueueButton].exists)
        XCTAssertTrue(app.buttons[IDs.downloadInlineCancelButton].exists)
    }

    func testQueueRunningJobShowsCancelWhenSeeded() {
        let app = makeApp()
        app.launchArguments.append(contentsOf: ["-uitest-seed-running-download", "-uitest-open-queue"])
        app.launch()

        XCTAssertTrue(app.buttons[IDs.queueJobCancelButton].waitForExistence(timeout: 5))
    }

    func testQueueFailedJobShowsRetryWhenSeeded() {
        let app = makeApp()
        app.launchArguments.append(contentsOf: ["-uitest-seed-failed-download", "-uitest-open-queue"])
        app.launch()

        XCTAssertTrue(app.buttons[IDs.queueJobRetryButton].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Seeded Failed Sample"].exists)
    }

    func testTranscribeWorkspaceShowsPrimaryControlsAndDefaultFormat() {
        let app = makeApp()
        app.launchArguments.append("-uitest-open-transcribe")
        app.launch()

        XCTAssertTrue(app.buttons[IDs.transcribeOpenButton].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[IDs.transcribeQueueButton].exists)
        let formatPicker = app.popUpButtons[IDs.transcribeFormatPicker]
        XCTAssertTrue(formatPicker.exists)
        XCTAssertEqual(formatPicker.value as? String, "Subtitles (.srt)")
    }

    func testDownloadSubtitleControlsAppearWhenWorkspaceIsSeeded() {
        let app = makeApp()
        app.launchArguments.append("-uitest-seed-subtitle-workspaces")
        app.launch()

        XCTAssertTrue(app.popUpButtons[IDs.downloadSubtitlePolicyPicker].waitForExistence(timeout: 5))
    }

    func testConvertSubtitleControlsAppearWhenWorkspaceIsSeeded() {
        let app = makeApp()
        app.launchArguments.append(contentsOf: ["-uitest-seed-subtitle-workspaces", "-uitest-open-convert"])
        app.launch()

        XCTAssertTrue(app.checkBoxes[IDs.convertSubtitleToggle].waitForExistence(timeout: 5))
    }

    func testTrimSubtitleControlsAppearWhenWorkspaceIsSeeded() {
        let app = makeApp()
        app.launchArguments.append("-uitest-open-trim")
        app.launch()

        XCTAssertTrue(app.checkBoxes[IDs.trimSubtitleToggle].waitForExistence(timeout: 5))
    }

    func testCompactWindowKeepsTrimAndQueueControlsReachable() {
        let trimApp = makeCompactApp()
        trimApp.launchArguments.append("-uitest-open-trim")
        trimApp.launch()

        XCTAssertTrue(trimApp.buttons[IDs.trimOpenButton].waitForExistence(timeout: 5))
        XCTAssertTrue(trimApp.checkBoxes[IDs.trimSubtitleToggle].exists)
        trimApp.terminate()

        let queueApp = makeCompactApp()
        queueApp.launchArguments.append("-uitest-open-queue")
        queueApp.launch()

        XCTAssertTrue(queueApp.staticTexts["No jobs yet"].waitForExistence(timeout: 5))
    }

    func testCompactSettingsWindowKeepsDefaultControlsReachable() {
        let app = makeCompactApp()
        app.launch()
        app.typeKey(",", modifierFlags: .command)

        XCTAssertTrue(app.staticTexts["Default download folder"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)[IDs.settingsOverwriteToggle].exists)
    }

    func testQueueAndHistoryExposeSubtitleArtifactAffordances() {
        let queueApp = makeApp()
        queueApp.launchArguments.append(contentsOf: ["-uitest-seed-transcribe", "-uitest-open-queue"])
        queueApp.launch()

        XCTAssertTrue(queueApp.buttons["Preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(queueApp.buttons["Transcribe"].exists)
        XCTAssertTrue(queueApp.staticTexts["sample-output.mp4 • sample-output.srt saved"].exists)
        queueApp.terminate()

        let historyApp = makeApp()
        historyApp.launchArguments.append(contentsOf: ["-uitest-seed-transcribe", "-uitest-open-history"])
        historyApp.launch()

        XCTAssertTrue(historyApp.buttons["Preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(historyApp.buttons["Transcribe"].exists)
        XCTAssertTrue(historyApp.staticTexts["sample-output.mp4 • sample-output.srt saved"].exists)
    }

    func testDownloadAuthControlsAppear() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(app.popUpButtons[IDs.downloadAuthPicker].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[IDs.downloadConfigureAuthButton].exists)
        XCTAssertTrue(app.staticTexts[IDs.downloadAuthSummary].exists)
    }

    func testDownloadAuthSheetOpensFromDownload() {
        let app = makeApp()
        app.launch()

        app.buttons[IDs.downloadConfigureAuthButton].click()

        XCTAssertTrue(app.popUpButtons[IDs.authSheetProfilePicker].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Details"].exists)
    }

    func testDownloadAuthSheetCanSwitchStrategyAndSteps() {
        let app = makeApp()
        app.launch()

        app.buttons[IDs.downloadConfigureAuthButton].click()

        let strategyPicker = app.popUpButtons[IDs.authSheetStrategyPicker]
        XCTAssertTrue(strategyPicker.waitForExistence(timeout: 5))
        strategyPicker.click()
        app.menuItems["Advanced Headers"].click()

        XCTAssertEqual(strategyPicker.value as? String, "Advanced Headers")
        app.buttons["Details"].click()
        XCTAssertTrue(app.staticTexts["Cookie header"].waitForExistence(timeout: 5))
        app.buttons["Finish"].click()
        XCTAssertTrue(app.staticTexts["Summary"].waitForExistence(timeout: 5))
    }

    func testDownloadAuthSeededProfileIsSelectedByDefault() {
        let app = makeApp()
        app.launchArguments.append("-uitest-seed-auth-profiles")
        app.launch()

        let authPicker = app.popUpButtons[IDs.downloadAuthPicker]
        XCTAssertTrue(authPicker.waitForExistence(timeout: 5))
        XCTAssertEqual(authPicker.value as? String, "Seeded Browser Auth")
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-uitest-isolated-auth-store")
        return app
    }

    private func makeCompactApp() -> XCUIApplication {
        let app = makeApp()
        app.launchArguments.append("-uitest-compact-window")
        return app
    }

    private func hasInlineProgressIndicator(in app: XCUIApplication) -> Bool {
        app.progressIndicators[IDs.downloadInlineProgress].exists
            || app.activityIndicators[IDs.downloadInlineProgress].exists
    }
}

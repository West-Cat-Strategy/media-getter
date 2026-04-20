import XCTest

@MainActor
final class MediaGetterUITests: XCTestCase {
    private enum IDs {
        static let downloadURLField = "download-url-field"
        static let downloadInspectButton = "download-inspect-button"
        static let downloadSubtitlePolicyPicker = "download-subtitle-policy-picker"
        static let convertSubtitleToggle = "convert-subtitle-toggle"
        static let trimSubtitleToggle = "trim-subtitle-toggle"
        static let sidebarConvert = "sidebar-convert"
        static let sidebarTrim = "sidebar-trim"
        static let transcribeOpenButton = "transcribe-open-button"
        static let transcribeQueueButton = "transcribe-queue-button"
        static let transcribeFormatPicker = "transcribe-format-picker"
    }

    func testPrimaryToolbarButtonsAppear() {
        let app = XCUIApplication()
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
        let app = XCUIApplication()
        app.launch()

        let urlFieldExists = app.textFields[IDs.downloadURLField].waitForExistence(timeout: 5)
        let inspectButtonExists = app.buttons[IDs.downloadInspectButton].exists

        XCTAssertTrue(urlFieldExists)
        XCTAssertTrue(inspectButtonExists)
    }

    func testTranscribeWorkspaceShowsPrimaryControlsAndDefaultFormat() {
        let app = XCUIApplication()
        app.launchArguments.append("-uitest-open-transcribe")
        app.launch()

        XCTAssertTrue(app.buttons[IDs.transcribeOpenButton].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[IDs.transcribeQueueButton].exists)
        let formatPicker = app.popUpButtons[IDs.transcribeFormatPicker]
        XCTAssertTrue(formatPicker.exists)
        XCTAssertEqual(formatPicker.value as? String, "Subtitles (.srt)")
    }

    func testDownloadSubtitleControlsAppearWhenWorkspaceIsSeeded() {
        let app = XCUIApplication()
        app.launchArguments.append("-uitest-seed-subtitle-workspaces")
        app.launch()

        XCTAssertTrue(app.popUpButtons[IDs.downloadSubtitlePolicyPicker].waitForExistence(timeout: 5))
    }

    func testConvertSubtitleControlsAppearWhenWorkspaceIsSeeded() {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-uitest-seed-subtitle-workspaces", "-uitest-open-convert"])
        app.launch()

        XCTAssertTrue(app.checkBoxes[IDs.convertSubtitleToggle].waitForExistence(timeout: 5))
    }

    func testTrimSubtitleControlsAppearWhenWorkspaceIsSeeded() {
        let app = XCUIApplication()
        app.launchArguments.append("-uitest-open-trim")
        app.launch()

        XCTAssertTrue(app.checkBoxes[IDs.trimSubtitleToggle].waitForExistence(timeout: 5))
    }

    func testQueueAndHistoryExposeSubtitleArtifactAffordances() {
        let queueApp = XCUIApplication()
        queueApp.launchArguments.append(contentsOf: ["-uitest-seed-transcribe", "-uitest-open-queue"])
        queueApp.launch()

        XCTAssertTrue(queueApp.buttons["Preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(queueApp.buttons["Transcribe"].exists)
        XCTAssertTrue(queueApp.staticTexts["Linked auto-subtitle job"].exists)
        queueApp.terminate()

        let historyApp = XCUIApplication()
        historyApp.launchArguments.append(contentsOf: ["-uitest-seed-transcribe", "-uitest-open-history"])
        historyApp.launch()

        XCTAssertTrue(historyApp.buttons["Preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(historyApp.buttons["Transcribe"].exists)
    }
}

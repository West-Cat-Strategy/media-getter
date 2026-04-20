import XCTest

@MainActor
final class MediaGetterUITests: XCTestCase {
    private enum IDs {
        static let downloadURLField = "download-url-field"
        static let downloadInspectButton = "download-inspect-button"
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
        XCTAssertEqual(formatPicker.value as? String, "Plain Text (.txt)")
    }

    func testQueueAndHistoryExposeTranscriptionAffordances() {
        let queueApp = XCUIApplication()
        queueApp.launchArguments.append(contentsOf: ["-uitest-seed-transcribe", "-uitest-open-queue"])
        queueApp.launch()

        XCTAssertTrue(queueApp.buttons["Open Transcript"].waitForExistence(timeout: 5))
        XCTAssertTrue(queueApp.buttons["Transcribe"].exists)
        queueApp.terminate()

        let historyApp = XCUIApplication()
        historyApp.launchArguments.append(contentsOf: ["-uitest-seed-transcribe", "-uitest-open-history"])
        historyApp.launch()

        XCTAssertTrue(historyApp.buttons["Open Transcript"].waitForExistence(timeout: 5))
        XCTAssertTrue(historyApp.buttons["Transcribe"].exists)
    }
}

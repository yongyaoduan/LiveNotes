import XCTest

@MainActor
final class LiveNotesUITests: XCTestCase {
    private var runningApp: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        runningApp?.terminate()
        runningApp = nil
    }

    func testHomeShowsSessionSidebarAndSavedStates() {
        let app = launchApp()

        XCTAssertTrue(app.buttons["New Recording"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Recordings"].exists)
        XCTAssertTrue(app.staticTexts["Neural Networks"].exists)
        XCTAssertTrue(app.buttons["Design Review, Finalizing · 62%"].exists)
        XCTAssertTrue(app.buttons["Recovered Audio, Recovered · 38 min"].exists)

        attachScreenshot(named: "home-session-sidebar", app: app)
    }

    func testNewRecordingFlowCreatesLiveSession() {
        let app = launchApp()

        app.buttons["New Recording"].click()
        XCTAssertTrue(app.staticTexts["New Recording"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["Recording Name"].exists)
        XCTAssertFalse(app.staticTexts["Meeting"].exists)
        XCTAssertFalse(app.staticTexts["Lecture"].exists)
        XCTAssertFalse(app.staticTexts["Tutorial"].exists)

        app.buttons["new-recording-start-button"].click()

        XCTAssertTrue(app.staticTexts["Before You Record"].waitForExistence(timeout: 3))
        app.checkBoxes["I have permission to record this session."].click()
        app.buttons["Start"].click()

        XCTAssertTrue(app.staticTexts["Transcript"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Current Topic"].exists)
        XCTAssertTrue(app.staticTexts["Recording · AI catching up · Auto-saved"].exists)

        attachScreenshot(named: "new-recording-flow", app: app)
    }

    func testLiveRecordingControlsAndStates() {
        let app = launchApp(arguments: ["--ui-state", "live"])
        XCTAssertTrue(app.staticTexts["Transcript"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Activation Functions"].exists)
        XCTAssertTrue(app.staticTexts["Translation"].exists)
        XCTAssertTrue(app.staticTexts[UITestText.activationFunctions].exists)
        XCTAssertTrue(app.staticTexts["Low confidence"].exists)

        app.buttons["recording-bar-pause-button"].click()
        XCTAssertTrue(app.staticTexts["Paused"].waitForExistence(timeout: 3))

        app.buttons["recording-bar-pause-button"].click()
        XCTAssertTrue(app.staticTexts["Recording · AI catching up · Auto-saved"].waitForExistence(timeout: 3))

        app.buttons["recording-bar-new-topic-button"].click()
        XCTAssertTrue(app.staticTexts["Optimization"].waitForExistence(timeout: 3))

        attachScreenshot(named: "live-recording-controls", app: app)
    }

    func testStopFinalizingAndSavedReview() {
        let app = launchApp(arguments: ["--ui-state", "live"])
        app.buttons["recording-bar-stop-button"].click()
        XCTAssertTrue(app.staticTexts["Stop recording?"].waitForExistence(timeout: 3))
        app.buttons["Stop and Save"].click()

        XCTAssertTrue(app.staticTexts["Finalizing recording"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Saving audio"].exists)
        XCTAssertTrue(app.staticTexts["Finalizing transcript"].exists)

        app.buttons["Open When Done"].click()
        XCTAssertTrue(app.staticTexts["Saved today 10:02"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Topics"].exists)
        XCTAssertTrue(app.buttons["Export"].exists)

        attachScreenshot(named: "saved-review", app: app)
    }

    func testExportAndSettingsSheets() {
        let app = launchApp(arguments: ["--ui-state", "saved"])
        app.buttons["saved-review-export-button"].click()
        XCTAssertTrue(app.staticTexts["Export"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Markdown"].exists)
        XCTAssertTrue(app.checkBoxes["Topic Notes"].exists)
        app.buttons["export-cancel-button"].click()

        app.buttons["Settings"].click()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Audio Input"].exists)
        XCTAssertTrue(app.staticTexts["Translate To"].exists)
        XCTAssertTrue(app.staticTexts["Local Only"].exists)
        XCTAssertTrue(app.staticTexts["Ready"].exists)

        attachScreenshot(named: "export-and-settings", app: app)
    }

    private func launchApp(
        arguments: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test"] + arguments
        app.launch()
        runningApp = app
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), file: file, line: line)
        return app
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private enum UITestText {
    static let activationFunctions = text([
        0x6FC0, 0x6D3B, 0x51FD, 0x6570, 0x5E2E, 0x52A9, 0x6A21, 0x578B,
        0x5B66, 0x4E60, 0x975E, 0x7EBF, 0x6027, 0x6A21, 0x5F0F, 0x3002
    ])

    private static func text(_ scalars: [UInt32]) -> String {
        String(String.UnicodeScalarView(scalars.compactMap(UnicodeScalar.init)))
    }
}

import XCTest

@MainActor
final class LiveNotesUITests: XCTestCase {
    private static var screenshotIndex = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testHomeShowsSessionSidebarAndSavedStates() {
        let app = launchApp()

        XCTAssertTrue(app.buttons["New Recording"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Recordings"].exists)
        XCTAssertTrue(app.staticTexts["Product Review"].exists)
        XCTAssertTrue(app.buttons["Design Review, Finalizing · 62%"].exists)
        XCTAssertTrue(app.buttons["Recovered Audio, Recovered · 38 min"].exists)
        XCTAssertFalse(app.buttons["Settings"].exists)

        attachScreenshot(named: "home-session-sidebar", app: app)

        app.buttons["Customer Call, Saved · 31 min"].click()
        XCTAssertTrue(app.staticTexts["Topic Notes"].waitForExistence(timeout: 3))
        attachScreenshot(named: "sidebar-select-saved-session", app: app)

        app.buttons["Recovered Audio, Recovered · 38 min"].click()
        XCTAssertTrue(app.staticTexts["Recovered Recording"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["LiveNotes found an unfinished recording with a preserved audio file."].exists)
        XCTAssertTrue(app.buttons["Process Audio"].exists)
        XCTAssertTrue(app.staticTexts["Finish the current recording before processing recovered audio."].exists)
        XCTAssertTrue(app.buttons["Return to Active Recording"].exists)
        XCTAssertFalse(app.buttons["recovered-new-recording-button"].exists)
        attachScreenshot(named: "sidebar-select-recovered-session", app: app)
    }

    func testNewRecordingFlowCreatesLiveSession() {
        let app = launchApp(arguments: ["--ui-state", "empty"])

        app.buttons["New Recording"].click()
        XCTAssertTrue(app.staticTexts["New Recording"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["Recording Name"].exists)
        XCTAssertFalse(app.staticTexts["Meeting"].exists)
        XCTAssertFalse(app.staticTexts["Lecture"].exists)
        XCTAssertFalse(app.staticTexts["Tutorial"].exists)
        XCTAssertFalse(app.staticTexts["Audio Input"].exists)
        XCTAssertFalse(app.staticTexts["Mode"].exists)
        attachScreenshot(named: "new-recording-sheet", app: app)
        app.buttons["new-recording-cancel-button"].click()
        XCTAssertTrue(waitForHittable(app.buttons["New Recording"], timeout: 5))
        XCTAssertFalse(app.textFields["Recording Name"].isHittable)
        attachScreenshot(named: "new-recording-cancelled", app: app)

        app.buttons["New Recording"].click()
        XCTAssertTrue(app.staticTexts["New Recording"].waitForExistence(timeout: 3))

        app.buttons["new-recording-start-button"].click()

        XCTAssertTrue(app.staticTexts["Before You Record"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Start"].isEnabled)
        attachScreenshot(named: "recording-consent-disabled", app: app)
        app.buttons["recording-consent-back-button"].click()
        XCTAssertTrue(app.staticTexts["New Recording"].waitForExistence(timeout: 3))
        attachScreenshot(named: "recording-consent-back", app: app)

        app.buttons["new-recording-start-button"].click()
        XCTAssertTrue(app.staticTexts["Before You Record"].waitForExistence(timeout: 3))
        app.checkBoxes["I have permission to record this session."].click()
        XCTAssertTrue(app.buttons["Start"].isEnabled)
        attachScreenshot(named: "recording-consent-enabled", app: app)
        app.buttons["recording-consent-start-button"].click()

        XCTAssertTrue(app.staticTexts["Transcript"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Current Topic"].exists)
        XCTAssertTrue(app.staticTexts["Waiting for speech..."].exists)
        XCTAssertFalse(app.buttons["topic-panel-split-topic-button"].exists)
        XCTAssertTrue(app.staticTexts["recording-duration-label"].exists)
        XCTAssertTrue(app.buttons["Pause"].exists)

        attachScreenshot(named: "new-recording-flow", app: app)
    }

    func testLiveRecordingControlsAndStates() {
        let app = launchApp(arguments: ["--ui-state", "live"])
        XCTAssertTrue(app.staticTexts["Transcript"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Decision Point"].exists)
        XCTAssertTrue(app.staticTexts["Translation"].exists)
        XCTAssertTrue(app.staticTexts[UITestText.tradeoff].exists)
        XCTAssertTrue(app.staticTexts["Low confidence"].exists)
        XCTAssertFalse(app.buttons["Bookmark"].exists)
        XCTAssertFalse(app.buttons["Rename"].exists)
        XCTAssertFalse(app.buttons["Jump to Live"].exists)
        XCTAssertFalse(app.buttons["topbar-stop-button"].exists)
        XCTAssertFalse(app.buttons["topic-panel-new-topic-button"].exists)
        XCTAssertFalse(app.buttons["recording-bar-new-topic-button"].exists)

        app.buttons["recording-bar-pause-button"].click()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 3))
        attachScreenshot(named: "live-recording-paused", app: app)

        app.buttons["recording-bar-pause-button"].click()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))
        attachScreenshot(named: "live-recording-resumed", app: app)

        app.buttons["topic-panel-split-topic-button"].click()
        XCTAssertTrue(app.staticTexts["Topic 2"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Notes will appear after more speech is processed."].exists)
        XCTAssertFalse(app.staticTexts["No summary yet."].exists)
        XCTAssertTrue(waitForAbsence(app.buttons["topic-panel-split-topic-button"]))

        attachScreenshot(named: "live-recording-controls", app: app)
    }

    func testPersistedPausedSessionShowsResumeState() {
        let app = launchApp(arguments: ["--ui-state", "paused"])

        XCTAssertTrue(app.staticTexts["Paused · 15:08"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Resume"].exists)
        XCTAssertFalse(app.buttons["Pause"].exists)

        attachScreenshot(named: "persisted-paused-state", app: app)
    }

    func testLiveRecordingDurationUpdatesWhileRecording() {
        let app = launchApp(arguments: ["--ui-state", "live"])
        let durationLabel = app.staticTexts["recording-duration-label"]

        XCTAssertTrue(durationLabel.waitForExistence(timeout: 5))
        let initialValue = textValue(of: durationLabel)
        XCTAssertTrue(waitForTextValueChange(durationLabel, from: initialValue, timeout: 3))

        attachScreenshot(named: "live-duration-updates", app: app)
    }

    func testNewRecordingDisabledDuringActiveSession() {
        let live = launchApp(arguments: ["--ui-state", "live"])
        XCTAssertTrue(live.staticTexts["Transcript"].waitForExistence(timeout: 5))
        XCTAssertFalse(live.buttons["New Recording"].isEnabled)
        attachScreenshot(named: "new-recording-disabled-live", app: live)
        live.terminate()

        let preparing = launchApp(arguments: ["--ui-state", "preparing"])
        XCTAssertTrue(preparing.staticTexts["Preparing recording"].waitForExistence(timeout: 5))
        XCTAssertFalse(preparing.buttons["New Recording"].isEnabled)
        attachScreenshot(named: "new-recording-disabled-preparing", app: preparing)
        preparing.terminate()

        let finalizing = launchApp(arguments: ["--ui-state", "finalizing-complete"])
        XCTAssertTrue(finalizing.staticTexts["Recording saved"].waitForExistence(timeout: 5))
        XCTAssertTrue(finalizing.staticTexts["Ready to review"].exists)
        XCTAssertFalse(finalizing.staticTexts["Finalizing · 100%"].exists)
        XCTAssertTrue(finalizing.buttons["New Recording"].isEnabled)
        attachScreenshot(named: "new-recording-enabled-finalizing-complete", app: finalizing)
    }

    func testStopShowsFinalizingProgress() {
        let app = launchApp(arguments: ["--ui-state", "live"])
        app.buttons["recording-bar-stop-button"].click()
        XCTAssertTrue(app.staticTexts["Stop recording?"].waitForExistence(timeout: 3))
        attachScreenshot(named: "stop-confirmation", app: app)
        app.buttons["stop-cancel-button"].click()
        XCTAssertTrue(waitForAbsence(app.staticTexts["Stop recording?"]))
        attachScreenshot(named: "stop-cancelled", app: app)

        app.buttons["recording-bar-stop-button"].click()
        XCTAssertTrue(app.staticTexts["Stop recording?"].waitForExistence(timeout: 3))
        app.buttons["stop-save-button"].click()

        XCTAssertTrue(app.staticTexts["Finalizing recording"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Saving audio"].exists)
        XCTAssertTrue(app.staticTexts["Finalizing transcript"].exists)
        XCTAssertTrue(app.staticTexts["Finalizing · 25%"].exists)
        XCTAssertFalse(app.buttons["Open When Done"].isEnabled)
        attachScreenshot(named: "finalizing-recording", app: app)

        XCTAssertTrue(app.staticTexts["Recording saved"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Ready to review"].exists)
        XCTAssertFalse(app.staticTexts["Finalizing · 100%"].exists)
        XCTAssertTrue(app.buttons["Open Review"].exists)
        XCTAssertTrue(app.buttons["open-when-done-button"].isEnabled)
        XCTAssertTrue(app.buttons["New Recording"].isEnabled)
        attachScreenshot(named: "finalizing-complete", app: app)
        app.buttons["open-when-done-button"].click()
        XCTAssertTrue(app.staticTexts["Saved · 15 min"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Topic Notes"].exists)
        attachScreenshot(named: "finalizing-open-saved-review", app: app)
    }

    func testSuccessfulInferenceAutoSavesGeneratedContent() {
        let storePath = temporaryStorePath()
        let app = launchApp(arguments: [
            "--ui-state", "live",
            "--ui-recording-runtime", "simulated",
            "--session-store", storePath
        ])

        app.buttons["recording-bar-stop-button"].click()
        XCTAssertTrue(app.staticTexts["Stop recording?"].waitForExistence(timeout: 3))
        app.buttons["stop-save-button"].click()

        XCTAssertTrue(app.staticTexts["Saved · 16 min"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Customer Follow-up"].exists)
        XCTAssertTrue(app.staticTexts["We should follow up with the customer before Friday."].exists)
        XCTAssertFalse(app.buttons["open-when-done-button"].exists)
        XCTAssertFalse(app.staticTexts["Finalizing · 100%"].exists)
        XCTAssertTrue(file(at: storePath, contains: "We should follow up with the customer before Friday."))

        attachScreenshot(named: "inference-auto-saved-review", app: app)
    }

    func testRecoveredAudioRetriesLocalInferenceWhenRuntimeIsReady() {
        let storePath = temporaryStorePath()
        let app = launchApp(arguments: [
            "--ui-state", "recovered",
            "--ui-recording-runtime", "simulated",
            "--ui-retry-recovered", "true",
            "--session-store", storePath
        ])

        XCTAssertTrue(app.staticTexts["Saved · 38 min"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Customer Follow-up"].exists)
        XCTAssertTrue(app.staticTexts["We should follow up with the customer before Friday."].exists)
        XCTAssertTrue(file(at: storePath, contains: "We should follow up with the customer before Friday."))

        attachScreenshot(named: "recovered-audio-inference-retry", app: app)
    }

    func testRecoveredAudioCanBeProcessedOnDemand() {
        let storePath = temporaryStorePath()
        let app = launchApp(arguments: [
            "--ui-state", "recovered",
            "--ui-recording-runtime", "simulated",
            "--session-store", storePath
        ])

        XCTAssertTrue(app.staticTexts["Recovered Recording"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Process Audio"].isEnabled)
        app.buttons["Process Audio"].click()

        XCTAssertTrue(app.staticTexts["Saved · 38 min"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Customer Follow-up"].exists)
        XCTAssertTrue(app.staticTexts["We should follow up with the customer before Friday."].exists)
        XCTAssertTrue(file(at: storePath, contains: "We should follow up with the customer before Friday."))
    }

    func testSavedReviewExportsMarkdown() {
        let storePath = temporaryStorePath()
        let exportPath = exportPath(forStorePath: storePath, title: "Product Review")
        let app = launchApp(arguments: [
            "--ui-state", "saved",
            "--session-store", storePath
        ])

        XCTAssertTrue(app.staticTexts["Saved · 52 min"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Topic Notes"].exists)
        XCTAssertTrue(app.staticTexts["Transcript"].exists)
        XCTAssertTrue(app.buttons["saved-review-export-button"].exists)
        app.buttons["saved-review-export-button"].click()
        XCTAssertTrue(app.staticTexts["Exported Markdown"].waitForExistence(timeout: 3))
        XCTAssertTrue(file(at: exportPath, contains: "# Product Review"))
        XCTAssertFalse(file(at: exportPath, contains: "Generated"))
        XCTAssertFalse(app.buttons["Settings"].exists)
        attachScreenshot(named: "saved-review", app: app)
    }

    func testSidebarShowsEmptyRecordingsState() {
        let app = launchApp(arguments: ["--ui-state", "empty"])

        XCTAssertTrue(app.staticTexts["No recordings yet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Start a recording to build your local library."].exists)

        attachScreenshot(named: "empty-recordings-sidebar", app: app)
    }

    func testPreparingAndFailedStatesDoNotShowLiveControls() {
        let preparing = launchApp(arguments: ["--ui-state", "preparing"])
        XCTAssertTrue(preparing.staticTexts["Preparing recording"].waitForExistence(timeout: 5))
        XCTAssertFalse(preparing.buttons["recording-bar-stop-button"].exists)
        attachScreenshot(named: "preparing-state", app: preparing)
        preparing.terminate()

        let failed = launchApp(arguments: ["--ui-state", "failed"])
        XCTAssertTrue(failed.staticTexts["Recording failed"].waitForExistence(timeout: 5))
        XCTAssertTrue(failed.staticTexts["Microphone access was interrupted."].exists)
        XCTAssertTrue(failed.buttons["New Recording"].exists)
        XCTAssertTrue(failed.buttons["Microphone Settings"].exists)
        XCTAssertFalse(failed.buttons["recording-bar-stop-button"].exists)
        attachScreenshot(named: "failed-state", app: failed)
    }

    func testMissingModelsDisableRecordingStart() {
        let app = launchApp(arguments: ["--ui-state", "empty", "--ui-model-status", "missing"])

        app.buttons["New Recording"].click()

        XCTAssertTrue(app.staticTexts["New Recording"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Required local models are not ready: whisper-large-v3-turbo and Qwen3-4B-4bit."].exists)
        XCTAssertTrue(app.buttons["Open Install Location"].exists)
        XCTAssertFalse(app.buttons["new-recording-start-button"].isEnabled)

        attachScreenshot(named: "missing-models-disable-start", app: app)
    }

    func testProductionLaunchReflectsRuntimeReadiness() {
        let storePath = temporaryStorePath()
        let app = launchApp(
            arguments: ["--session-store", storePath],
            includeUITestArgument: false
        )

        XCTAssertTrue(app.staticTexts["Select a recording or start a new one"].waitForExistence(timeout: 5))
        app.buttons["New Recording"].click()

        XCTAssertTrue(app.staticTexts["New Recording"].waitForExistence(timeout: 3))
        let reasonVisible = app.staticTexts["recording-unavailable-reason"].exists
        XCTAssertEqual(app.buttons["new-recording-start-button"].isEnabled, !reasonVisible)

        attachScreenshot(named: "production-runtime-readiness", app: app)
    }

    private func launchApp(
        arguments: [String] = [],
        includeUITestArgument: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (includeUITestArgument ? ["--ui-test"] : []) + arguments
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), file: file, line: line)
        return app
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let screenshot = app.windows.firstMatch.exists
            ? app.windows.firstMatch.screenshot()
            : app.screenshot()
        let evidenceDirectory = ProcessInfo.processInfo.environment["LIVENOTES_UI_EVIDENCE_DIR"]
            ?? NSHomeDirectory() + "/Library/Caches/LiveNotesUITestEvidence"
        do {
            Self.screenshotIndex += 1
            let directoryURL = URL(fileURLWithPath: evidenceDirectory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let fileName = String(format: "%02d-%@.png", Self.screenshotIndex, safeFileName(name))
            try screenshot.pngRepresentation.write(
                to: directoryURL.appendingPathComponent(fileName),
                options: .atomic
            )
        } catch {
            XCTFail("Could not write UI evidence screenshot: \(error.localizedDescription)")
        }
    }

    private func waitForAbsence(
        _ element: XCUIElement,
        timeout: TimeInterval = 1
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return !element.exists
    }

    private func waitForTextValueChange(
        _ element: XCUIElement,
        from initialValue: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, textValue(of: element) != initialValue {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return element.exists && textValue(of: element) != initialValue
    }

    private func waitForHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.isHittable {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return element.exists && element.isHittable
    }

    private func textValue(of element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    private func safeFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }
        return scalars.joined()
    }

    private func temporaryStorePath() -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LiveNotesUITests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("sessions.json").path
    }

    private func exportPath(forStorePath storePath: String, title: String) -> String {
        URL(fileURLWithPath: storePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Exports", isDirectory: true)
            .appendingPathComponent("\(title).md")
            .path
    }

    private func file(at path: String, contains expectedText: String) -> Bool {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }
        return content.contains(expectedText)
    }
}

private enum UITestText {
    static let tradeoff = text([
        0x4E3B, 0x8981, 0x53D6, 0x820D, 0x662F, 0x901F, 0x5EA6,
        0x548C, 0x51C6, 0x786E, 0x6027, 0x3002
    ])

    private static func text(_ scalars: [UInt32]) -> String {
        String(String.UnicodeScalarView(scalars.compactMap(UnicodeScalar.init)))
    }
}

import AVFoundation
import XCTest

@MainActor
final class LiveNotesUITests: XCTestCase {
    private static var screenshotIndex = 0
    private let liveSessionID = "11111111-2222-3333-4444-555555555555"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testHomeShowsSessionSidebarAndSavedStates() {
        let app = launchApp()

        XCTAssertTrue(app.staticTexts["Recordings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Recording in Progress"].exists)
        XCTAssertTrue(app.staticTexts["Recording in progress."].exists)
        XCTAssertTrue(app.staticTexts["Recordings"].exists)
        XCTAssertTrue(app.staticTexts["Morning Session"].exists)
        XCTAssertTrue(app.buttons["Design Review, Finalizing · 62%"].exists)
        XCTAssertTrue(app.buttons["Unsaved Recording, Unsaved audio · 38 min"].exists)
        XCTAssertFalse(app.buttons["Settings"].exists)

        attachScreenshot(named: "home-session-sidebar", app: app)
        app.terminate()

        let saved = launchApp(arguments: ["--ui-state", "saved"])
        saved.buttons["Customer Update, 31 min recording · Saved locally"].click()
        XCTAssertTrue(saved.staticTexts["Transcript"].waitForExistence(timeout: 3))
        attachScreenshot(named: "sidebar-select-saved-session", app: saved)
        saved.terminate()

        let recovered = launchApp(arguments: [
            "--ui-state", "recovered",
            "--ui-recording-runtime", "simulated",
            "--session-store", temporaryStorePath()
        ])
        XCTAssertTrue(recovered.staticTexts["Unsaved Recording"].waitForExistence(timeout: 3))
        XCTAssertTrue(recovered.staticTexts["Create a saved transcript and translation from this audio."].exists)
        XCTAssertTrue(recovered.staticTexts["Unsaved recording · 38 min"].exists)
        XCTAssertTrue(recovered.buttons["Recover & Save"].exists)
        XCTAssertTrue(recovered.buttons["Leave Unsaved"].exists)
        XCTAssertFalse(recovered.buttons["recovered-new-recording-button"].exists)
        attachScreenshot(named: "sidebar-select-recovered-session", app: recovered)
    }

    func testCommandQQuitsApplication() {
        let app = launchApp(arguments: ["--ui-state", "empty"])

        XCTAssertTrue(app.staticTexts["Recordings"].waitForExistence(timeout: 5))
        app.typeKey("q", modifierFlags: [.command])

        XCTAssertTrue(waitForAppToTerminate(app, timeout: 3))
    }

    func testNewRecordingFlowCreatesLiveSession() {
        let app = launchApp(arguments: ["--ui-state", "empty"])

        app.buttons["New Recording"].click()
        XCTAssertTrue(app.staticTexts["Before You Record"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Continue"].isEnabled)
        XCTAssertTrue(app.staticTexts["Check the box to continue."].exists)
        attachScreenshot(named: "recording-consent-disabled", app: app)
        app.buttons["recording-consent-back-button"].click()
        XCTAssertTrue(waitForHittable(app.buttons["New Recording"], timeout: 5))
        attachScreenshot(named: "recording-consent-back", app: app)

        app.buttons["New Recording"].click()
        XCTAssertTrue(app.staticTexts["Before You Record"].waitForExistence(timeout: 3))
        app.checkBoxes["I understand that I must have permission to record."].click()
        XCTAssertTrue(app.buttons["Continue"].isEnabled)
        attachScreenshot(named: "recording-consent-enabled", app: app)
        app.buttons["recording-consent-start-button"].click()
        XCTAssertTrue(app.staticTexts["New Recording"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Name"].exists)
        XCTAssertTrue(app.staticTexts["Transcription and translation run on this Mac."].exists)
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
        XCTAssertTrue(app.staticTexts["Before You Record"].waitForExistence(timeout: 3))
        app.checkBoxes["I understand that I must have permission to record."].click()
        app.buttons["recording-consent-start-button"].click()
        XCTAssertTrue(app.staticTexts["New Recording"].waitForExistence(timeout: 3))
        app.buttons["new-recording-start-button"].click()

        XCTAssertTrue(app.staticTexts["Transcript"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Current Topic"].exists)
        XCTAssertTrue(app.staticTexts["Listening for speech..."].exists)
        XCTAssertTrue(app.staticTexts["Listening"].exists)
        XCTAssertFalse(app.staticTexts["Stored locally"].exists)
        XCTAssertTrue(app.buttons["Finish & Save"].exists)
        XCTAssertFalse(app.staticTexts["Input activity"].exists)
        XCTAssertFalse(app.buttons["topic-panel-split-topic-button"].exists)
        XCTAssertTrue(app.staticTexts["recording-duration-label"].exists)
        XCTAssertTrue(app.buttons["Pause"].exists)

        attachScreenshot(named: "new-recording-flow", app: app)
    }

    func testRecordingConsentIsRememberedForTheNextRecording() {
        let storePath = temporaryStorePath()
        let app = launchApp(arguments: ["--ui-state", "empty", "--session-store", storePath])
        startRecordingThroughConsent(app)
        XCTAssertTrue(app.buttons["recording-bar-stop-button"].waitForExistence(timeout: 3))
        app.buttons["recording-bar-stop-button"].click()
        app.buttons["stop-save-button"].click()
        XCTAssertTrue(app.buttons["saved-review-export-button"].waitForExistence(timeout: 3))

        app.buttons["New Recording"].click()

        let nameField = app.textFields["Recording Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Before You Record"].exists)
        XCTAssertFalse(app.buttons["recording-bar-stop-button"].exists)
        XCTAssertTrue(app.buttons["new-recording-start-button"].isEnabled)
        nameField.click()
        app.typeKey("a", modifierFlags: [.command])
        nameField.typeText("Team planning")
        app.buttons["new-recording-start-button"].click()

        XCTAssertTrue(app.buttons["recording-bar-stop-button"].waitForExistence(timeout: 3))
        XCTAssertTrue(file(at: storePath, contains: "Team planning"))
        attachScreenshot(named: "remembered-consent-keeps-recording-name", app: app)
    }

    func testRecordingConsentPersistsAcrossApplicationLaunches() {
        let storePath = temporaryStorePath()
        let arguments = ["--ui-state", "empty", "--session-store", storePath]
        let app = launchApp(arguments: arguments)
        startRecordingThroughConsent(app)
        XCTAssertTrue(app.buttons["recording-bar-stop-button"].waitForExistence(timeout: 3))
        app.terminate()
        let relaunched = launchApp(arguments: arguments)

        relaunched.buttons["New Recording"].click()

        let nameField = relaunched.textFields["Recording Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        XCTAssertFalse(relaunched.staticTexts["Before You Record"].exists)
        XCTAssertFalse(relaunched.buttons["recording-bar-stop-button"].exists)
        XCTAssertTrue(relaunched.buttons["new-recording-start-button"].isEnabled)
        nameField.click()
        relaunched.typeKey("a", modifierFlags: [.command])
        nameField.typeText("Lecture after restart")
        relaunched.buttons["new-recording-start-button"].click()

        XCTAssertTrue(relaunched.buttons["recording-bar-stop-button"].waitForExistence(timeout: 3))
        XCTAssertTrue(file(at: storePath, contains: "Lecture after restart"))
    }

    func testCancellingLaterRecordingNameDoesNotCreateARecordingOrForgetConsent() throws {
        let storePath = temporaryStorePath()
        let app = launchApp(arguments: ["--ui-state", "empty", "--session-store", storePath])
        startRecordingThroughConsent(app)
        XCTAssertTrue(app.buttons["recording-bar-stop-button"].waitForExistence(timeout: 3))
        app.buttons["recording-bar-stop-button"].click()
        app.buttons["stop-save-button"].click()
        XCTAssertTrue(app.buttons["saved-review-export-button"].waitForExistence(timeout: 3))
        let savedLibrary = try Data(contentsOf: URL(fileURLWithPath: storePath))

        app.buttons["New Recording"].click()
        XCTAssertTrue(app.textFields["Recording Name"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Before You Record"].exists)
        XCTAssertFalse(app.buttons["recording-bar-stop-button"].exists)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: storePath)), savedLibrary)
        app.buttons["new-recording-cancel-button"].click()

        XCTAssertTrue(app.buttons["saved-review-export-button"].waitForExistence(timeout: 3))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: storePath)), savedLibrary)
        app.buttons["New Recording"].click()
        XCTAssertTrue(app.textFields["Recording Name"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Before You Record"].exists)
        XCTAssertTrue(app.buttons["new-recording-start-button"].isEnabled)
    }

    func testCancelledRecordingConsentIsNotRememberedAcrossLaunches() {
        let arguments = ["--ui-state", "empty", "--session-store", temporaryStorePath()]
        let app = launchApp(arguments: arguments)
        app.buttons["New Recording"].click()
        XCTAssertTrue(app.staticTexts["Before You Record"].waitForExistence(timeout: 3))
        app.checkBoxes["I understand that I must have permission to record."].click()
        app.buttons["recording-consent-back-button"].click()
        app.terminate()
        let relaunched = launchApp(arguments: arguments)

        relaunched.buttons["New Recording"].click()

        XCTAssertTrue(relaunched.staticTexts["Before You Record"].waitForExistence(timeout: 3))
        XCTAssertFalse(relaunched.buttons["Continue"].isEnabled)
    }

    func testCancelledFirstRecordingDoesNotRememberConsentAcrossLaunches() {
        let arguments = ["--ui-state", "empty", "--session-store", temporaryStorePath()]
        let app = launchApp(arguments: arguments)
        app.buttons["New Recording"].click()
        XCTAssertTrue(app.staticTexts["Before You Record"].waitForExistence(timeout: 3))
        app.checkBoxes["I understand that I must have permission to record."].click()
        app.buttons["recording-consent-start-button"].click()
        XCTAssertTrue(app.buttons["new-recording-cancel-button"].waitForExistence(timeout: 3))
        app.buttons["new-recording-cancel-button"].click()
        app.terminate()
        let relaunched = launchApp(arguments: arguments)

        relaunched.buttons["New Recording"].click()

        XCTAssertTrue(relaunched.staticTexts["Before You Record"].waitForExistence(timeout: 3))
        XCTAssertFalse(relaunched.buttons["Continue"].isEnabled)
    }

    func testNewRecordingClearsStaleLiveSpeechFailure() {
        let app = launchApp(arguments: [
            "--ui-state", "empty",
            "--ui-recording-runtime", "simulated",
            "--ui-persistence-status", "Live speech recognition failed.",
            "--session-store", temporaryStorePath()
        ])

        XCTAssertTrue(app.staticTexts["Live speech recognition failed."].waitForExistence(timeout: 3))

        startRecordingThroughConsent(app)

        XCTAssertTrue(app.staticTexts["Transcript"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Live speech recognition failed."].exists)
    }

    func testLiveTranscriptScrollsToCurrentPreview() {
        let app = launchApp(arguments: ["--ui-state", "long-live"])

        let preview = app.staticTexts["We are checking the audio and confirming the transcript is clear."]
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForElementInWindow(preview, app: app, timeout: 8))
        XCTAssertTrue(waitForElementOutsideWindow(
            app.staticTexts["Transcript segment 1 keeps the recording history visible."],
            app: app,
            timeout: 3
        ))
    }

    func testRecordingWaitsForLiveTranscriptionAndCanCancelPreparation() {
        let storePath = temporaryStorePath()
        let app = launchApp(arguments: [
            "--ui-state", "empty",
            "--ui-recording-runtime", "simulated",
            "--ui-live-transcriber", "hanging",
            "--session-store", storePath
        ])

        startRecordingThroughConsent(app)

        XCTAssertTrue(app.buttons["preparation-cancel-button"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Pause"].exists)
        XCTAssertFalse(app.buttons["recording-bar-stop-button"].exists)
        XCTAssertFalse(audioDirectoryHasFiles(forStorePath: storePath))
        cancelPreparation(app)

        XCTAssertTrue(app.staticTexts["No recordings yet"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["New Recording"].isEnabled)
        XCTAssertFalse(audioDirectoryHasFiles(forStorePath: storePath))
        XCTAssertFalse(file(at: storePath, contains: "audioFileName"))
        attachScreenshot(named: "speech-preparation-cancelled-before-recording", app: app)
    }

    func testRecordingFailsWhenAudioStartDoesNotReturn() {
        let app = launchApp(arguments: [
            "--ui-state", "empty",
            "--ui-recording-runtime", "hanging-audio",
            "--ui-audio-start-timeout", "0.5",
            "--session-store", temporaryStorePath()
        ])

        startRecordingThroughConsent(app)

        XCTAssertTrue(app.staticTexts["Recording failed"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["failed-microphone-settings-button"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["failed-retry-recording-button"].exists)
        XCTAssertFalse(app.staticTexts["Setting up recording"].exists)
        XCTAssertTrue(app.staticTexts["No recordings yet"].exists)

        attachScreenshot(named: "audio-start-timeout-failed-state", app: app)
    }

    func testRecordingWaitsWhenPermissionPreflightDoesNotReturn() {
        let app = launchApp(arguments: [
            "--ui-state", "empty",
            "--ui-recording-runtime", "simulated",
            "--ui-recording-preflight", "hanging",
            "--ui-audio-start-timeout", "0.5",
            "--session-store", temporaryStorePath()
        ])

        startRecordingThroughConsent(app)

        RunLoop.current.run(until: Date().addingTimeInterval(3.0))
        XCTAssertTrue(app.staticTexts["Waiting for macOS permission"].exists)
        XCTAssertEqual(app.progressIndicators.count, 0)
        XCTAssertTrue(app.staticTexts["Microphone access"].exists)
        XCTAssertTrue(app.staticTexts["Speech recognition"].exists)
        XCTAssertTrue(app.staticTexts["Audio input"].exists)
        XCTAssertTrue(app.staticTexts["Allow in macOS prompt"].exists)
        XCTAssertTrue(app.staticTexts["Starts after permission"].exists)
        XCTAssertTrue(app.staticTexts["Finish or cancel setup first."].exists)
        XCTAssertTrue(app.staticTexts["Allow Microphone and Speech Recognition in the macOS prompts."].exists)
        XCTAssertTrue(app.buttons["Open Microphone Settings"].exists)
        XCTAssertTrue(app.buttons["Open Speech Recognition Settings"].exists)
        XCTAssertTrue(app.buttons["preparation-cancel-button"].exists)
        XCTAssertFalse(app.staticTexts["Recording failed"].exists)
        XCTAssertTrue(app.staticTexts["Setup in progress"].exists)

        attachScreenshot(named: "permission-preflight-still-pending", app: app)
    }

    func testRecordingFailsWhenSpeechPreflightIsDeniedWithoutCreatingSession() {
        let app = launchApp(arguments: [
            "--ui-state", "empty",
            "--ui-recording-runtime", "simulated",
            "--ui-recording-preflight", "speech-denied",
            "--session-store", temporaryStorePath()
        ])

        startRecordingThroughConsent(app)

        XCTAssertTrue(app.staticTexts["Recording failed"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["LiveNotes needs permission to transcribe audio."].exists)
        XCTAssertTrue(app.buttons["failed-speech-settings-button"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["failed-retry-recording-button"].exists)
        XCTAssertTrue(app.staticTexts["No recordings yet"].exists)

        attachScreenshot(named: "speech-preflight-denied-failed-state", app: app)
    }

    func testPermissionPreflightDoesNotUseAudioStartTimeout() {
        let app = launchApp(arguments: [
            "--ui-state", "empty",
            "--ui-recording-runtime", "simulated",
            "--ui-recording-preflight", "hanging",
            "--ui-audio-start-timeout", "0.2",
            "--session-store", temporaryStorePath()
        ])

        startRecordingThroughConsent(app)

        RunLoop.current.run(until: Date().addingTimeInterval(2.0))
        XCTAssertTrue(app.staticTexts["Waiting for macOS permission"].exists)
        XCTAssertEqual(app.progressIndicators.count, 0)
        XCTAssertTrue(app.staticTexts["Microphone access"].exists)
        XCTAssertTrue(app.staticTexts["Speech recognition"].exists)
        XCTAssertTrue(app.buttons["Open Microphone Settings"].exists)
        XCTAssertTrue(app.buttons["Open Speech Recognition Settings"].exists)
        XCTAssertFalse(app.staticTexts["Recording failed"].exists)
        XCTAssertTrue(app.staticTexts["Setup in progress"].exists)

        attachScreenshot(named: "permission-preflight-does-not-use-audio-timeout", app: app)
    }

    func testRecordingPreparationCanBeCancelledWithoutCreatingSession() {
        let app = launchApp(arguments: [
            "--ui-state", "empty",
            "--ui-recording-runtime", "simulated",
            "--ui-recording-preflight", "hanging",
            "--session-store", temporaryStorePath()
        ])

        startRecordingThroughConsent(app)

        XCTAssertTrue(app.staticTexts["Setting up recording"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["preparation-cancel-button"].waitForExistence(timeout: 2))
        attachScreenshot(named: "recording-preparation-cancellable", app: app)

        cancelPreparation(app)
        XCTAssertTrue(waitForHittable(app.buttons["empty-start-recording-button"], timeout: 3))
        XCTAssertTrue(app.staticTexts["Ready to record"].exists)
        XCTAssertTrue(app.buttons["empty-start-recording-button"].exists)
        XCTAssertTrue(app.staticTexts["No recordings yet"].exists)
        XCTAssertFalse(app.staticTexts["Recording failed"].exists)

        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        XCTAssertTrue(waitForHittable(app.buttons["empty-start-recording-button"], timeout: 3))
        XCTAssertFalse(app.staticTexts["Recording failed"].exists)

        attachScreenshot(named: "recording-preparation-cancelled", app: app)
    }

    func testRecordingPreparationCancelPreventsLateAudioStart() {
        let storePath = temporaryStorePath()
        let app = launchApp(arguments: [
            "--ui-state", "empty",
            "--ui-recording-runtime", "observable",
            "--ui-recording-preflight", "delayed-success",
            "--session-store", storePath
        ])

        startRecordingThroughConsent(app)

        XCTAssertTrue(app.buttons["preparation-cancel-button"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["recording-bar-stop-button"].exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForHittable(app.buttons["empty-start-recording-button"], timeout: 3))

        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        XCTAssertFalse(app.staticTexts["Transcript"].exists)
        XCTAssertFalse(app.staticTexts["Recording failed"].exists)
        XCTAssertFalse(audioDirectoryHasFiles(forStorePath: storePath))
    }

    func testLiveRecordingControlsAndStates() {
        let app = launchApp(arguments: ["--ui-state", "live"])
        XCTAssertTrue(app.staticTexts["Transcript"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Session Notes"].exists)
        XCTAssertTrue(app.staticTexts["Translation"].exists)
        XCTAssertFalse(app.staticTexts["Stored locally"].exists)
        XCTAssertFalse(app.staticTexts["Input activity"].exists)
        XCTAssertTrue(app.staticTexts[UITestText.claritySentence].exists)
        XCTAssertFalse(app.staticTexts["Low confidence"].exists)
        XCTAssertFalse(app.buttons["Bookmark"].exists)
        XCTAssertFalse(app.buttons["Rename"].exists)
        XCTAssertFalse(app.buttons["Jump to Live"].exists)
        XCTAssertFalse(app.buttons["topbar-stop-button"].exists)
        XCTAssertFalse(app.buttons["topic-panel-new-topic-button"].exists)
        XCTAssertFalse(app.buttons["recording-bar-new-topic-button"].exists)
        XCTAssertFalse(app.buttons["topic-panel-split-topic-button"].exists)

        app.buttons["recording-bar-pause-button"].click()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Recording is paused."].exists)
        XCTAssertFalse(app.staticTexts["Listening for the next complete sentence..."].exists)
        attachScreenshot(named: "live-recording-paused", app: app)

        app.buttons["recording-bar-pause-button"].click()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))
        attachScreenshot(named: "live-recording-resumed", app: app)

        attachScreenshot(named: "live-recording-controls", app: app)
    }

    func testLiveRecordingShowsCurrentSpeechPreview() {
        let app = launchApp(arguments: ["--ui-state", "live"])

        XCTAssertTrue(app.staticTexts["Transcribing"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[UITestText.livePreviewEnglish].exists)
        XCTAssertEqual(textValue(of: app.staticTexts["live-transcript-preview"]), UITestText.livePreviewEnglish)
        XCTAssertEqual(textValue(of: app.staticTexts["live-translation-preview"]), UITestText.livePreview)
        XCTAssertTrue(app.staticTexts[UITestText.livePreview].exists)

        attachScreenshot(named: "live-current-speech-preview", app: app)
    }

    func testSpeechCapturedBeforePausePersistsWhilePausedAndAfterResume() {
        let storePath = temporaryStorePath()
        let app = launchApp(arguments: [
            "--ui-state", "empty",
            "--ui-recording-runtime", "simulated",
            "--ui-live-transcriber", "pause-tail",
            "--session-store", storePath
        ])
        let tailText = "Speech captured before pausing still belongs to the recording."
        startRecordingThroughConsent(app)
        XCTAssertTrue(app.buttons["recording-bar-pause-button"].waitForExistence(timeout: 3))
        XCTAssertTrue(transcriptRows(storePath: storePath).isEmpty)

        app.buttons["recording-bar-pause-button"].click()

        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Recording is paused."].exists)
        XCTAssertTrue(app.staticTexts[tailText].waitForExistence(timeout: 3))
        XCTAssertTrue(waitForFile(at: storePath, contains: tailText, timeout: 3))
        let pausedTranscript = transcriptRows(storePath: storePath)
        XCTAssertEqual(pausedTranscript.count, 1)
        XCTAssertEqual(pausedTranscript.first?["text"] as? String, tailText)
        XCTAssertTrue(file(at: storePath, contains: "\"paused\""))
        app.buttons["recording-bar-pause-button"].click()

        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts[tailText].exists)
        XCTAssertEqual(transcriptRows(storePath: storePath) as NSArray, pausedTranscript as NSArray)
        attachScreenshot(named: "speech-before-pause-retained-after-resume", app: app)
    }

    func testSpeechFailureRemainsVisibleAfterBufferedResultsUntilNewRecording() {
        let storePath = temporaryStorePath()
        let app = launchApp(arguments: [
            "--ui-state", "empty",
            "--ui-recording-runtime", "simulated",
            "--ui-live-transcriber", "failed-tail",
            "--session-store", storePath
        ])
        let tailText = "Speech captured before pausing still belongs to the recording."
        let failureText = "Live speech recognition failed."
        startRecordingThroughConsent(app)
        XCTAssertTrue(app.buttons["recording-bar-pause-button"].waitForExistence(timeout: 3))
        app.buttons["recording-bar-pause-button"].click()

        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts[tailText].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts[failureText].waitForExistence(timeout: 3))
        XCTAssertTrue(waitForFile(at: storePath, contains: tailText, timeout: 3))
        let pausedTranscript = transcriptRows(storePath: storePath)
        XCTAssertEqual(pausedTranscript.count, 1)
        app.buttons["recording-bar-stop-button"].click()
        XCTAssertTrue(app.staticTexts["Finish Recording?"].waitForExistence(timeout: 3))
        app.buttons["stop-save-button"].click()

        XCTAssertTrue(app.buttons["saved-review-export-button"].waitForExistence(timeout: 3))
        XCTAssertEqual(transcriptRows(storePath: storePath) as NSArray, pausedTranscript as NSArray)
        XCTAssertTrue(app.staticTexts[failureText].exists)
        app.buttons["New Recording"].click()
        XCTAssertTrue(app.textFields["Recording Name"].waitForExistence(timeout: 3))
        app.buttons["new-recording-start-button"].click()

        XCTAssertTrue(app.buttons["recording-bar-pause-button"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts[failureText].exists)
        XCTAssertTrue(transcriptRows(storePath: storePath).isEmpty)
        XCTAssertTrue(file(at: storePath, contains: tailText))
        attachScreenshot(named: "speech-failure-cleared-for-new-recording", app: app)
    }

    func testPersistedPausedSessionShowsResumeState() {
        let app = launchApp(arguments: ["--ui-state", "paused"])

        XCTAssertTrue(app.staticTexts["Paused"].waitForExistence(timeout: 5))
        XCTAssertEqual(textValue(of: app.staticTexts["recording-duration-label"]), "15:08")
        XCTAssertTrue(app.staticTexts["Recording is paused."].exists)
        XCTAssertFalse(app.staticTexts["14:43 - 21:29"].exists)
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
        XCTAssertFalse(live.buttons["Recording in Progress"].exists)
        XCTAssertTrue(live.staticTexts["Recording in progress."].exists)
        attachScreenshot(named: "new-recording-disabled-live", app: live)
        live.terminate()

        let preparing = launchApp(arguments: ["--ui-state", "preparing"])
        XCTAssertTrue(preparing.staticTexts["Setting up recording"].waitForExistence(timeout: 5))
        XCTAssertFalse(preparing.buttons["Setup in Progress"].exists)
        XCTAssertFalse(preparing.staticTexts["Finish setup or cancel it first."].exists)
        XCTAssertTrue(preparing.staticTexts["Finish or cancel setup first."].exists)
        XCTAssertTrue(preparing.buttons["preparation-cancel-button"].exists)
        XCTAssertTrue(preparing.staticTexts["Microphone access"].exists)
        XCTAssertTrue(preparing.staticTexts["Speech recognition"].exists)
        attachScreenshot(named: "new-recording-disabled-preparing", app: preparing)
        preparing.terminate()

        let finalizing = launchApp(arguments: ["--ui-state", "finalizing-complete"])
        XCTAssertTrue(finalizing.staticTexts["Transcript"].waitForExistence(timeout: 5))
        XCTAssertTrue(finalizing.staticTexts["Morning Session"].exists)
        XCTAssertFalse(finalizing.staticTexts["Finalizing · 100%"].exists)
        XCTAssertFalse(finalizing.buttons["Open Recording"].exists)
        XCTAssertTrue(finalizing.buttons["New Recording"].isEnabled)
        attachScreenshot(named: "new-recording-enabled-finalizing-complete", app: finalizing)
    }

    func testFinishSavesCurrentRecordingImmediately() {
        let app = launchApp(arguments: ["--ui-state", "live"])
        app.buttons["recording-bar-stop-button"].click()
        XCTAssertTrue(app.staticTexts["Finish Recording?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["LiveNotes will save the recording, current transcript, and available translations."].exists)
        XCTAssertTrue(app.buttons["Finish & Save"].exists)
        XCTAssertTrue(app.buttons["Keep Recording"].exists)
        attachScreenshot(named: "stop-confirmation", app: app)
        app.buttons["stop-cancel-button"].click()
        XCTAssertTrue(waitForAbsence(app.staticTexts["Finish Recording?"]))
        XCTAssertTrue(app.buttons["Pause"].exists)

        app.buttons["recording-bar-stop-button"].click()
        XCTAssertTrue(app.staticTexts["Finish Recording?"].waitForExistence(timeout: 3))
        app.buttons["stop-save-button"].click()

        XCTAssertTrue(app.staticTexts["15 min recording · Saved locally"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Morning Session"].exists)
        XCTAssertTrue(app.staticTexts["We start with the customer problem."].exists)
        XCTAssertFalse(app.buttons["Open Recording"].exists)
        XCTAssertTrue(app.buttons["New Recording"].isEnabled)
        XCTAssertTrue(app.staticTexts["Transcript"].exists)
        attachScreenshot(named: "current-recording-saved", app: app)
    }

    func testFinishPreservesCurrentTranscriptAndTranslationsWithoutInference() {
        for inferenceOutput in ["success", "short", "throw"] {
            let storePath = temporaryStorePath()
            let app = launchApp(arguments: [
                "--ui-state", "live",
                "--ui-recording-runtime", "simulated",
                "--ui-inference-output", inferenceOutput,
                "--session-store", storePath
            ])
            let originalTranscript = transcriptRows(forSessionID: liveSessionID, storePath: storePath)
            XCTAssertEqual(originalTranscript.count, 2)
            XCTAssertTrue(originalTranscript.allSatisfy { !($0["translation"] as? String ?? "").isEmpty })

            app.buttons["recording-bar-stop-button"].click()
            XCTAssertTrue(app.staticTexts["Finish Recording?"].waitForExistence(timeout: 3))
            app.buttons["stop-save-button"].click()

            XCTAssertTrue(app.staticTexts["16 min recording · Saved locally"].waitForExistence(timeout: 3))
            XCTAssertEqual(
                transcriptRows(forSessionID: liveSessionID, storePath: storePath) as NSArray,
                originalTranscript as NSArray
            )
            XCTAssertFalse(app.staticTexts["Final transcription failed. Saved the live transcript."].exists)
            XCTAssertFalse(app.staticTexts["Final file transcript."].exists)
            XCTAssertFalse(file(at: storePath, contains: "We confirmed the launch checklist before Friday."))
            let audioFilePath = firstAudioFilePath(forStorePath: storePath)
            XCTAssertTrue(audioFileIsDecodable(at: audioFilePath))
            attachScreenshot(named: "current-transcript-preserved-\(inferenceOutput)", app: app)
            app.terminate()
        }
    }

    func testProductionLoopbackRecordsTranscribesSavesAndExports() throws {
        let fixturePath = e2eConfigValue(
            fileName: "livenotes-e2e-audio-fixture-path.txt",
            fallback: "/tmp/livenotes-e2e-audio-fixture.wav"
        )
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixturePath),
            "Audio fixture is missing at \(fixturePath)."
        )
        let expectedPhrase = e2eConfigValue(
            fileName: "livenotes-e2e-expected-phrase.txt",
            fallback: "grammar"
        )
        let inputMode = e2eConfigValue(
            fileName: "livenotes-e2e-mode.txt",
            fallback: "loopback"
        )
        let nativeInference = e2eConfigValue(
            fileName: "livenotes-e2e-native-inference.txt",
            fallback: "true"
        ) == "true"
        let expectedPhrasesJSON = e2eConfigValue(
            fileName: "livenotes-e2e-expected-phrases.json",
            fallback: "[]"
        )
        let expectedPhrases = try JSONDecoder().decode([String].self, from: Data(expectedPhrasesJSON.utf8))
        let minimumDuration = Double(e2eConfigValue(
            fileName: "livenotes-e2e-min-duration-seconds.txt",
            fallback: "20"
        )) ?? 20
        let storePath = temporaryStorePath()
        let exportDirectory = URL(fileURLWithPath: storePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Exports", isDirectory: true)
        var launchArguments = [
            "--session-store", storePath,
            "--export-directory", exportDirectory.path
        ]
        if inputMode == "audio-file" {
            XCTAssertTrue(nativeInference, "Audio-file verification requires native speech recognition.")
            launchArguments = [
                "--ui-state", "empty",
                "--ui-recording-runtime", "audio-file",
                "--ui-audio-fixture", fixturePath,
                "--ui-native-inference", "true"
            ] + launchArguments
        }
        let app = launchApp(
            arguments: launchArguments,
            includeUITestArgument: inputMode == "audio-file"
        )
        allowSystemPermissionPrompts()

        startRecordingThroughConsent(app)

        XCTAssertTrue(waitForRecordingAllowingSystemPrompts(app, timeout: 30))
        XCTAssertTrue(app.buttons["recording-bar-stop-button"].waitForExistence(timeout: 20))
        let playbackStartedAt = Date()
        var liveSamples: [[String: Any]] = []
        var lastSampleTime: TimeInterval = -1
        func sampleLiveTranscript() {
            let elapsed = Date().timeIntervalSince(playbackStartedAt)
            guard elapsed - lastSampleTime >= 1 else { return }
            lastSampleTime = elapsed
            let preview = app.staticTexts["live-transcript-preview"]
            let translation = app.staticTexts["live-translation-preview"]
            liveSamples.append([
                "elapsedSeconds": elapsed,
                "text": transcriptTexts(storePath: storePath).joined(separator: " "),
                "preview": preview.exists ? textValue(of: preview) : "",
                "previewTranslation": translation.exists ? textValue(of: translation) : ""
            ])
        }
        if inputMode == "audio-file" {
            let playbackDeadline = Date().addingTimeInterval(try audioDurationSeconds(at: fixturePath) + 1)
            while Date() < playbackDeadline {
                sampleLiveTranscript()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
        } else {
            try playAudioFixture(at: fixturePath, sample: sampleLiveTranscript)
        }
        app.activate()
        XCTAssertTrue(app.buttons["recording-bar-stop-button"].waitForExistence(timeout: 10))
        let liveText = transcriptTexts(storePath: storePath).joined(separator: " ")
        let liveVisibleText = app.staticTexts.allElementsBoundByIndex.map { textValue(of: $0) }.joined(separator: " ")
        let previewTranslationElement = app.staticTexts["live-translation-preview"]
        let previewTranslationBeforeStop = previewTranslationElement.exists
            ? textValue(of: previewTranslationElement) : ""
        let liveEvidence: [String: Any] = [
            "fixturePath": fixturePath,
            "fixtureDurationSeconds": try audioDurationSeconds(at: fixturePath),
            "inputMode": inputMode,
            "nativeSpeechRecognition": nativeInference,
            "expectedPhrases": [expectedPhrase] + expectedPhrases,
            "minimumDurationSeconds": minimumDuration,
            "liveSamples": liveSamples,
            "liveTextBeforeStop": liveText,
            "visibleTextBeforeStop": liveVisibleText,
            "previewTranslationBeforeStop": previewTranslationBeforeStop,
            "sessionStorePath": storePath
        ]
        let liveEvidenceData = try JSONSerialization.data(withJSONObject: liveEvidence, options: [.prettyPrinted, .sortedKeys])
        try liveEvidenceData.write(
            to: URL(fileURLWithPath: storePath).deletingLastPathComponent()
                .appendingPathComponent("live-speech-before-save.json"),
            options: .atomic
        )
        let liveEvidenceAttachment = XCTAttachment(data: liveEvidenceData, uniformTypeIdentifier: "public.json")
        liveEvidenceAttachment.name = "Live speech before saving"
        liveEvidenceAttachment.lifetime = .keepAlways
        add(liveEvidenceAttachment)
        attachScreenshot(named: "production-live-transcript-before-save", app: app)
        let liveScreenshotAttachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        liveScreenshotAttachment.name = "Live transcript before saving"
        liveScreenshotAttachment.lifetime = .keepAlways
        add(liveScreenshotAttachment)
        for phrase in [expectedPhrase] + expectedPhrases {
            XCTAssertTrue(
                normalizedSpeechText(liveText + " " + liveVisibleText).contains(normalizedSpeechText(phrase)),
                "Live transcript is missing: \(phrase). Stored transcript: \(liveText). Visible text: \(liveVisibleText)"
            )
        }
        app.buttons["recording-bar-stop-button"].click()
        XCTAssertTrue(app.staticTexts["Finish Recording?"].waitForExistence(timeout: 5))
        let stopStartedAt = Date()
        app.buttons["stop-save-button"].click()

        XCTAssertTrue(app.buttons["saved-review-export-button"].waitForExistence(timeout: 30))
        let stopToSavedSeconds = Date().timeIntervalSince(stopStartedAt)
        let audioFilePath = waitForAudioFilePath(forStorePath: storePath, timeout: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioFilePath))
        XCTAssertGreaterThan(fileSize(at: audioFilePath), 0)
        XCTAssertTrue(audioFileIsDecodable(at: audioFilePath))
        XCTAssertGreaterThanOrEqual(try audioDurationSeconds(at: audioFilePath), minimumDuration)
        XCTAssertGreaterThan(try audioRMSLevel(at: audioFilePath), 0.005)
        XCTAssertTrue(waitForFile(at: storePath, contains: expectedPhrase, timeout: 3))
        let savedTranscript = transcriptRows(storePath: storePath)
        let savedText = savedTranscript.compactMap { $0["text"] as? String }.joined(separator: " ")
        let savedTranslations = savedTranscript.compactMap { $0["translation"] as? String }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !previewTranslationBeforeStop.isEmpty, previewTranslationBeforeStop != "Translating..." {
            XCTAssertFalse(savedTranslations.isEmpty, "The visible translation was lost while saving.")
        }
        for phrase in expectedPhrases {
            XCTAssertTrue(
                normalizedSpeechText(savedText).contains(normalizedSpeechText(phrase)),
                "Saved transcript is missing: \(phrase)"
            )
        }

        let exportStartedAt = Date()
        app.buttons["saved-review-export-button"].click()
        XCTAssertTrue(waitForExport(forStorePath: storePath, containing: expectedPhrase, timeout: 10))
        let exportedMarkdownURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: exportDirectory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "md" }
        )
        let exportedMarkdown = try String(contentsOf: exportedMarkdownURL, encoding: .utf8)
        let exportedAudioURL = exportedMarkdownURL.deletingPathExtension()
            .appendingPathExtension(URL(fileURLWithPath: audioFilePath).pathExtension)
        let exportedAudioReady = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: exportedAudioURL.path) },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [exportedAudioReady], timeout: 10), .completed)
        XCTAssertEqual(
            try Data(contentsOf: exportedAudioURL),
            try Data(contentsOf: URL(fileURLWithPath: audioFilePath))
        )
        for sentence in savedTranscript {
            let text = try XCTUnwrap(sentence["text"] as? String)
            XCTAssertTrue(exportedMarkdown.contains(text), "Exported transcript is missing: \(text)")
            if let translation = sentence["translation"] as? String, !translation.isEmpty {
                XCTAssertTrue(exportedMarkdown.contains(translation), "Exported translation is missing: \(translation)")
            }
        }
        let exportedFilesReadySeconds = Date().timeIntervalSince(exportStartedAt)
        app.activate()
        let exportStatus = app.descendants(matching: .any)["saved-review-export-status"]
        let completedExport = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Saved to \(exportedMarkdownURL.path)"),
            object: exportStatus
        )
        XCTAssertEqual(XCTWaiter.wait(for: [completedExport], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["saved-review-export-button"].isEnabled)
        let exportSeconds = Date().timeIntervalSince(exportStartedAt)
        XCTAssertFalse(app.sheets.staticTexts["Export Incomplete?"].exists)
        let evidence: [String: Any] = [
            "inputMode": inputMode,
            "nativeSpeechRecognition": true,
            "expectedPhrases": expectedPhrases,
            "liveSamples": liveSamples,
            "liveTextBeforeStop": liveText,
            "visibleTextBeforeStop": liveVisibleText,
            "previewTranslationBeforeStop": previewTranslationBeforeStop,
            "savedText": savedText,
            "savedTranslations": savedTranslations,
            "stopToSavedSeconds": stopToSavedSeconds,
            "exportedFilesReadySeconds": exportedFilesReadySeconds,
            "exportSeconds": exportSeconds,
            "sessionStorePath": storePath,
            "recordedAudioPath": audioFilePath,
            "exportedAudioPath": exportedAudioURL.path,
            "exportedMarkdownPath": exportedMarkdownURL.path
        ]
        let evidenceData = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        let evidenceURL = URL(fileURLWithPath: storePath).deletingLastPathComponent()
            .appendingPathComponent("live-speech-evidence.json")
        try evidenceData.write(to: evidenceURL, options: .atomic)
        let attachment = XCTAttachment(data: evidenceData, uniformTypeIdentifier: "public.json")
        attachment.name = "Live speech and export measurements"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.activate()
        attachScreenshot(named: "production-loopback-record-transcribe-save-export", app: app)
    }

    func testFinishDoesNotWaitForPendingTranslations() {
        let storePath = temporaryStorePath()
        let app = launchApp(arguments: [
            "--ui-state", "live-partial",
            "--ui-recording-runtime", "simulated",
            "--ui-translation-mode", "hanging",
            "--ui-final-save-translation-timeout", "60",
            "--session-store", storePath
        ])
        let originalTranscript = transcriptRows(forSessionID: liveSessionID, storePath: storePath)
        XCTAssertEqual(originalTranscript.count, 2)
        XCTAssertEqual(originalTranscript.last?["translation"] as? String, "")

        app.buttons["recording-bar-stop-button"].click()
        XCTAssertTrue(app.staticTexts["Finish Recording?"].waitForExistence(timeout: 3))
        app.buttons["stop-save-button"].click()

        XCTAssertTrue(app.staticTexts["16 min recording · Saved locally"].waitForExistence(timeout: 3))
        XCTAssertEqual(
            transcriptRows(forSessionID: liveSessionID, storePath: storePath) as NSArray,
            originalTranscript as NSArray
        )
        XCTAssertTrue(app.buttons["saved-review-export-button"].isEnabled)
        XCTAssertTrue(app.staticTexts["Translation unavailable."].exists)
        attachScreenshot(named: "saved-with-pending-translation", app: app)
    }

    func testFinalSpeechTailKeepsVisibleTranslationAndEarlierSentences() {
        let storePath = temporaryStorePath()
        let app = launchApp(arguments: [
            "--ui-state", "live",
            "--ui-recording-runtime", "simulated",
            "--ui-live-transcriber", "final-tail",
            "--ui-translation-mode", "hanging",
            "--session-store", storePath
        ])
        let originalTranscript = transcriptRows(forSessionID: liveSessionID, storePath: storePath)
        XCTAssertEqual(originalTranscript.count, 2)
        XCTAssertTrue(app.staticTexts[UITestText.livePreview].waitForExistence(timeout: 3))
        app.buttons["recording-bar-stop-button"].click()
        XCTAssertTrue(app.staticTexts["Finish Recording?"].waitForExistence(timeout: 3))
        app.buttons["stop-save-button"].click()

        XCTAssertTrue(app.buttons["saved-review-export-button"].waitForExistence(timeout: 3))
        let savedTranscript = transcriptRows(forSessionID: liveSessionID, storePath: storePath)
        XCTAssertEqual(savedTranscript.count, originalTranscript.count + 1)
        XCTAssertEqual(Array(savedTranscript.prefix(originalTranscript.count)) as NSArray, originalTranscript as NSArray)
        XCTAssertEqual(savedTranscript.last?["text"] as? String, UITestText.livePreviewEnglish)
        XCTAssertEqual(savedTranscript.last?["translation"] as? String, UITestText.livePreview)
        XCTAssertFalse(app.staticTexts["Translation unavailable."].exists)
        attachScreenshot(named: "final-speech-tail-keeps-visible-translation", app: app)
    }

    func testFinalSpeechTailKeepsAndExportsVisiblePartialTranslation() {
        let storePath = temporaryStorePath()
        let app = launchApp(arguments: [
            "--ui-state", "live",
            "--ui-recording-runtime", "simulated",
            "--ui-live-transcriber", "final-tail-extended",
            "--ui-translation-mode", "hanging",
            "--session-store", storePath
        ])
        let originalTranscript = transcriptRows(forSessionID: liveSessionID, storePath: storePath)
        let finalText = String(UITestText.livePreviewEnglish.dropLast()) + " before the recording ends."
        let partialTranslation = "[Partial translation] " + UITestText.livePreview
        XCTAssertTrue(app.staticTexts[UITestText.livePreview].waitForExistence(timeout: 3))
        app.buttons["recording-bar-stop-button"].click()
        XCTAssertTrue(app.staticTexts["Finish Recording?"].waitForExistence(timeout: 3))
        app.buttons["stop-save-button"].click()

        XCTAssertTrue(app.buttons["saved-review-export-button"].waitForExistence(timeout: 3))
        let savedTranscript = transcriptRows(forSessionID: liveSessionID, storePath: storePath)
        XCTAssertEqual(Array(savedTranscript.prefix(originalTranscript.count)) as NSArray, originalTranscript as NSArray)
        XCTAssertEqual(savedTranscript.last?["text"] as? String, finalText)
        XCTAssertEqual(savedTranscript.last?["translation"] as? String, partialTranslation)
        XCTAssertTrue(app.staticTexts[partialTranslation].exists)
        let exportPath = exportPath(forStorePath: storePath, title: "Morning Session")
        app.buttons["saved-review-export-button"].click()

        XCTAssertTrue(waitForFile(at: exportPath, contains: partialTranslation, timeout: 3))
        XCTAssertTrue(file(at: exportPath, contains: finalText))
        app.activate()
        attachScreenshot(named: "final-speech-tail-keeps-visible-partial-translation", app: app)
    }

    func testRevisedFinalSpeechTailDoesNotInheritAnUnrelatedPreviewTranslation() {
        for transcriber in ["final-tail-revised", "final-tail-word-revised"] {
            let storePath = temporaryStorePath()
            let app = launchApp(arguments: [
                "--ui-state", "live",
                "--ui-recording-runtime", "simulated",
                "--ui-live-transcriber", transcriber,
                "--ui-translation-mode", "hanging",
                "--session-store", storePath
            ])
            let originalTranscript = transcriptRows(forSessionID: liveSessionID, storePath: storePath)
            XCTAssertTrue(app.staticTexts[UITestText.livePreview].waitForExistence(timeout: 3))
            app.buttons["recording-bar-stop-button"].click()
            XCTAssertTrue(app.staticTexts["Finish Recording?"].waitForExistence(timeout: 3))
            app.buttons["stop-save-button"].click()

            XCTAssertTrue(app.buttons["saved-review-export-button"].waitForExistence(timeout: 3))
            let savedTranscript = transcriptRows(forSessionID: liveSessionID, storePath: storePath)
            XCTAssertEqual(Array(savedTranscript.prefix(originalTranscript.count)) as NSArray, originalTranscript as NSArray)
            XCTAssertEqual(savedTranscript.last?["translation"] as? String, "")
            XCTAssertFalse(app.staticTexts[UITestText.livePreview].exists)
            app.terminate()
        }
    }

    func testExportWithMissingTranslationsSavesCurrentSnapshotWithoutPrompt() {
        let storePath = temporaryStorePath()
        let app = launchApp(arguments: [
            "--ui-state", "live-partial",
            "--ui-recording-runtime", "simulated",
            "--ui-translation-mode", "hanging",
            "--ui-final-save-translation-timeout", "60",
            "--session-store", storePath
        ])
        app.buttons["recording-bar-stop-button"].click()
        XCTAssertTrue(app.staticTexts["Finish Recording?"].waitForExistence(timeout: 3))
        app.buttons["stop-save-button"].click()
        XCTAssertTrue(app.buttons["saved-review-export-button"].waitForExistence(timeout: 3))
        let savedTranscript = transcriptRows(forSessionID: liveSessionID, storePath: storePath)
        let sourceAudioPath = firstAudioFilePath(forStorePath: storePath)
        let originalAudio = try? Data(contentsOf: URL(fileURLWithPath: sourceAudioPath))
        XCTAssertNotNil(originalAudio)
        let exportPath = exportPath(forStorePath: storePath, title: "Morning Session")

        app.buttons["saved-review-export-button"].click()

        XCTAssertTrue(waitForFile(at: exportPath, contains: "Translation unavailable.", timeout: 3))
        XCTAssertFalse(app.sheets.staticTexts["Export Incomplete?"].exists)
        for sentence in savedTranscript {
            XCTAssertTrue(file(at: exportPath, contains: sentence["text"] as? String ?? ""))
            if let translation = sentence["translation"] as? String, !translation.isEmpty {
                XCTAssertTrue(file(at: exportPath, contains: translation))
            }
        }
        let exportedAudioURL = URL(fileURLWithPath: exportPath).deletingPathExtension().appendingPathExtension("m4a")
        XCTAssertEqual(try? Data(contentsOf: exportedAudioURL), originalAudio)
        XCTAssertEqual(
            transcriptRows(forSessionID: liveSessionID, storePath: storePath) as NSArray,
            savedTranscript as NSArray
        )
        attachScreenshot(named: "partial-translation-exported-directly", app: app)
    }

    func testFinishSavesAudioWhenNoCommittedTranscriptExists() {
        let storePath = temporaryStorePath()
        let app = launchApp(arguments: [
            "--ui-state", "live-preview-only",
            "--ui-recording-runtime", "simulated",
            "--ui-inference-output", "throw",
            "--session-store", storePath
        ])
        XCTAssertTrue(app.staticTexts["Transcribing"].waitForExistence(timeout: 3))
        XCTAssertTrue(transcriptRows(forSessionID: liveSessionID, storePath: storePath).isEmpty)
        app.buttons["recording-bar-stop-button"].click()
        XCTAssertTrue(app.staticTexts["Finish Recording?"].waitForExistence(timeout: 3))
        app.buttons["stop-save-button"].click()

        XCTAssertTrue(app.buttons["saved-review-export-button"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Recording failed"].exists)
        XCTAssertTrue(transcriptRows(forSessionID: liveSessionID, storePath: storePath).isEmpty)
        XCTAssertFalse(file(at: storePath, contains: UITestText.livePreviewEnglish))
        XCTAssertTrue(audioFileIsDecodable(at: firstAudioFilePath(forStorePath: storePath)))
        attachScreenshot(named: "audio-saved-without-committed-transcript", app: app)
    }

    func testPausedRecordingCanFinishAndSave() {
        let storePath = temporaryStorePath()
        let app = launchApp(arguments: [
            "--ui-state", "paused",
            "--ui-recording-runtime", "simulated",
            "--session-store", storePath
        ])
        let originalTranscript = transcriptRows(forSessionID: liveSessionID, storePath: storePath)
        app.buttons["recording-bar-stop-button"].click()
        XCTAssertTrue(app.staticTexts["Finish Recording?"].waitForExistence(timeout: 3))
        app.buttons["stop-save-button"].click()

        XCTAssertTrue(app.buttons["saved-review-export-button"].waitForExistence(timeout: 3))
        XCTAssertEqual(
            transcriptRows(forSessionID: liveSessionID, storePath: storePath) as NSArray,
            originalTranscript as NSArray
        )
        XCTAssertTrue(app.buttons["New Recording"].isEnabled)
        XCTAssertTrue(audioFileIsDecodable(at: firstAudioFilePath(forStorePath: storePath)))
        attachScreenshot(named: "paused-recording-saved", app: app)
    }

    func testRecoveredAudioRetriesLocalInferenceWhenRuntimeIsReady() {
        let storePath = temporaryStorePath()
        let app = launchApp(arguments: [
            "--ui-state", "recovered",
            "--ui-recording-runtime", "simulated",
            "--ui-retry-recovered", "true",
            "--session-store", storePath
        ])

        XCTAssertTrue(app.staticTexts["38 min recording · Saved locally"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Recovered Session"].exists)
        XCTAssertFalse(app.staticTexts["Launch Checklist"].exists)
        XCTAssertTrue(app.staticTexts["We confirmed the launch checklist before Friday."].exists)
        XCTAssertTrue(file(at: storePath, contains: "We confirmed the launch checklist before Friday."))

        attachScreenshot(named: "recovered-audio-inference-retry", app: app)
    }

    func testRecoveredAudioCanBeProcessedOnDemand() {
        let storePath = temporaryStorePath()
        let app = launchApp(arguments: [
            "--ui-state", "recovered",
            "--ui-recording-runtime", "simulated",
            "--session-store", storePath
        ])

        XCTAssertTrue(app.staticTexts["Unsaved Recording"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Recover & Save"].isEnabled)
        app.buttons["Recover & Save"].click()

        XCTAssertTrue(app.staticTexts["38 min recording · Saved locally"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Recovered Session"].exists)
        XCTAssertFalse(app.staticTexts["Launch Checklist"].exists)
        XCTAssertTrue(app.staticTexts["We confirmed the launch checklist before Friday."].exists)
        XCTAssertTrue(file(at: storePath, contains: "We confirmed the launch checklist before Friday."))
    }

    func testSavedReviewExportsMarkdown() {
        let storePath = temporaryStorePath()
        let exportPath = exportPath(forStorePath: storePath, title: "Morning Session")
        let exportedAudioPath = URL(fileURLWithPath: exportPath)
            .deletingPathExtension()
            .appendingPathExtension("m4a")
            .path
        let app = launchApp(arguments: [
            "--ui-state", "saved",
            "--session-store", storePath
        ])

        XCTAssertTrue(app.staticTexts["52 min recording · Saved locally"].waitForExistence(timeout: 5))
        let sourceAudioPath = firstAudioFilePath(forStorePath: storePath)
        let sourceAudioData = try? Data(contentsOf: URL(fileURLWithPath: sourceAudioPath))
        XCTAssertNotNil(sourceAudioData)
        XCTAssertFalse(app.staticTexts["Topic Notes"].exists)
        XCTAssertTrue(app.staticTexts["Transcript"].exists)
        XCTAssertTrue(app.buttons["saved-review-export-button"].exists)
        app.buttons["saved-review-export-button"].click()
        XCTAssertTrue(waitForFile(at: exportPath, contains: "# Morning Session", timeout: 3))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedAudioPath))
        XCTAssertGreaterThan(fileSize(at: exportedAudioPath), 0)
        XCTAssertTrue(audioFileIsDecodable(at: exportedAudioPath))
        XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: exportedAudioPath)), sourceAudioData)
        XCTAssertFalse(file(at: exportPath, contains: "Generated"))
        app.activate()
        app.buttons["Customer Update, 31 min recording · Saved locally"].click()
        XCTAssertTrue(app.staticTexts["Transcript"].waitForExistence(timeout: 3))
        XCTAssertFalse(staticText(app, labeled: "Saved to \(exportPath)").exists)
        XCTAssertFalse(app.buttons["Settings"].exists)
        attachScreenshot(named: "saved-review", app: app)
    }

    func testSavedReviewExportFailsWhenSourceAudioIsMissing() {
        let storePath = temporaryStorePath()
        let exportPath = exportPath(forStorePath: storePath, title: "Morning Session")
        let exportedAudioPath = URL(fileURLWithPath: exportPath)
            .deletingPathExtension()
            .appendingPathExtension("m4a")
            .path
        let app = launchApp(arguments: [
            "--ui-state", "saved",
            "--session-store", storePath
        ])

        XCTAssertTrue(app.staticTexts["52 min recording · Saved locally"].waitForExistence(timeout: 5))
        let sourceAudioPath = firstAudioFilePath(forStorePath: storePath)
        XCTAssertFalse(sourceAudioPath.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceAudioPath))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: sourceAudioPath))

        app.buttons["saved-review-export-button"].click()

        let exportStatus = app.descendants(matching: .any)["saved-review-export-status"]
        XCTAssertTrue(exportStatus.waitForExistence(timeout: 3))
        let failureStatus = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "Could not export Markdown."),
            object: exportStatus
        )
        XCTAssertEqual(XCTWaiter.wait(for: [failureStatus], timeout: 3), .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportedAudioPath))
    }

    func testSidebarShowsEmptyRecordingsState() {
        let app = launchApp(arguments: ["--ui-state", "empty"])

        XCTAssertTrue(app.staticTexts["No recordings yet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saved recordings will appear here."].exists)
        XCTAssertTrue(app.staticTexts["Ready to record"].exists)
        XCTAssertTrue(app.staticTexts["Record locally. Transcription and translation stay on this Mac."].exists)
        XCTAssertTrue(app.buttons["empty-start-recording-button"].exists)

        attachScreenshot(named: "empty-recordings-sidebar", app: app)
    }

    func testPreparingAndFailedStatesDoNotShowLiveControls() {
        let preparing = launchApp(arguments: ["--ui-state", "preparing"])
        XCTAssertTrue(preparing.staticTexts["Setting up recording"].waitForExistence(timeout: 5))
        XCTAssertFalse(preparing.buttons["recording-bar-stop-button"].exists)
        attachScreenshot(named: "preparing-state", app: preparing)
        preparing.terminate()

        let failed = launchApp(arguments: ["--ui-state", "failed"])
        XCTAssertTrue(failed.staticTexts["Recording failed"].waitForExistence(timeout: 5))
        XCTAssertTrue(failed.staticTexts["Microphone access is unavailable. Check macOS Microphone privacy settings and try again."].exists)
        XCTAssertTrue(failed.buttons["failed-retry-recording-button"].exists)
        XCTAssertTrue(failed.buttons["Try Recording Again"].exists)
        XCTAssertTrue(failed.buttons["Open Microphone Settings"].exists)
        XCTAssertFalse(failed.buttons["recording-bar-stop-button"].exists)
        attachScreenshot(named: "failed-state", app: failed)
    }

    func testLegacyModelStatusDoesNotDisableRecordingStart() {
        let app = launchApp(arguments: ["--ui-state", "empty", "--ui-model-status", "missing"])

        XCTAssertTrue(app.buttons["New Recording"].isEnabled)
        XCTAssertFalse(app.staticTexts["Local processing is unavailable."].exists)
        XCTAssertFalse(app.staticTexts["Install the local processing files before recording."].exists)
        XCTAssertFalse(app.staticTexts["Local transcription, translation, and notes need the required model files."].exists)
        XCTAssertFalse(app.buttons["Open Processing Folder"].exists)
        XCTAssertFalse(app.buttons["Check Again"].exists)
        XCTAssertTrue(app.staticTexts["Ready to record"].exists)
        XCTAssertTrue(app.buttons["empty-start-recording-button"].exists)

        attachScreenshot(named: "legacy-model-status-does-not-disable-start", app: app)
    }

    func testProductionLaunchUsesAppleServicesWithoutModelArtifacts() {
        let storePath = temporaryStorePath()
        let artifactsRoot = temporaryArtifactsRoot()
        let app = launchApp(
            arguments: [
                "--session-store", storePath,
                "--model-artifacts-root", artifactsRoot.path
            ],
            includeUITestArgument: false
        )

        XCTAssertTrue(app.buttons["New Recording"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["New Recording"].isEnabled)
        XCTAssertFalse(app.staticTexts["Local processing is unavailable."].exists)
        XCTAssertFalse(app.staticTexts["Install the local processing files before recording."].exists)
        XCTAssertFalse(app.staticTexts["Local transcription, translation, and notes need the required model files."].exists)
        XCTAssertFalse(app.buttons["Open Processing Folder"].exists)
        XCTAssertFalse(app.buttons["Check Again"].exists)
        XCTAssertTrue(app.staticTexts["Ready to record"].exists)
        XCTAssertTrue(app.buttons["empty-start-recording-button"].exists)

        attachScreenshot(named: "production-apple-services-ready", app: app)
    }

    private func startRecordingThroughConsent(_ app: XCUIApplication) {
        app.buttons["New Recording"].click()
        XCTAssertTrue(app.staticTexts["Before You Record"].waitForExistence(timeout: 3))
        app.checkBoxes["I understand that I must have permission to record."].click()
        XCTAssertTrue(app.buttons["Continue"].isEnabled)
        app.buttons["recording-consent-start-button"].click()
        XCTAssertTrue(app.staticTexts["New Recording"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["new-recording-start-button"].isEnabled)
        app.buttons["new-recording-start-button"].click()
    }

    private func cancelPreparation(_ app: XCUIApplication) {
        app.buttons["preparation-cancel-button"].click()
        if app.buttons["preparation-cancel-button"].exists {
            app.activate()
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    private func launchApp(
        arguments: [String] = [],
        includeUITestArgument: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (includeUITestArgument ? ["--ui-test"] : []) + arguments
        app.terminate()
        allowSystemPermissionPrompts()
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

    private func elementIsInWindow(_ element: XCUIElement, app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        let window = app.windows.firstMatch
        guard window.exists else { return false }
        return !element.frame.isEmpty && window.frame.intersects(element.frame)
    }

    private func waitForElementInWindow(
        _ element: XCUIElement,
        app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if elementIsInWindow(element, app: app) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return elementIsInWindow(element, app: app)
    }

    private func waitForElementOutsideWindow(
        _ element: XCUIElement,
        app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !elementIsInWindow(element, app: app) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return !elementIsInWindow(element, app: app)
    }

    private func textValue(of element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    private func staticText(_ app: XCUIApplication, labeled label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func e2eConfigValue(fileName: String, fallback: String) -> String {
        let directories = [
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            URL(fileURLWithPath: "/tmp", isDirectory: true)
        ]
        for directory in directories {
            let url = directory.appendingPathComponent(fileName)
            guard let value = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                continue
            }
            return value
        }
        return fallback
    }

    private func allowSystemPermissionPrompts() {
        addUIInterruptionMonitor(withDescription: "System permissions") { alert in
            self.clickSystemPermissionButton(in: alert)
        }
    }

    private func waitForRecordingAllowingSystemPrompts(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.buttons["recording-bar-stop-button"].exists {
                return true
            }
            if dismissSystemPermissionPrompts() {
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                continue
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return app.buttons["recording-bar-stop-button"].exists
    }

    private func dismissSystemPermissionPrompts() -> Bool {
        for bundleIdentifier in ["com.apple.SecurityAgent", "com.apple.UserNotificationCenter"] {
            let systemApp = XCUIApplication(bundleIdentifier: bundleIdentifier)
            if clickSystemPermissionButton(in: systemApp) {
                return true
            }
        }
        return false
    }

    private func clickSystemPermissionButton(in element: XCUIElement) -> Bool {
        let hasPromptText = elementContainsSystemPrivacyPrompt(element)
        let hasNotificationPermissionButtons = element.buttons["action-button-1"].exists
            && element.buttons["action-button-3"].exists
        guard hasPromptText || hasNotificationPermissionButtons else {
            return false
        }

        let allowedLabels = ["Allow", "OK", "Continue"]
        let preferredButton = element.buttons.matching(
            NSPredicate(format: "label IN %@ OR title IN %@", allowedLabels, allowedLabels)
        ).firstMatch
        if preferredButton.exists {
            preferredButton.click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.75))
            return true
        }

        let fallbackButton = element.buttons["action-button-1"]
        guard fallbackButton.exists else {
            return false
        }

        fallbackButton.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.75))
        return true
    }

    private func elementContainsSystemPrivacyPrompt(_ element: XCUIElement) -> Bool {
        let promptPredicate = NSPredicate(
            format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@ OR label CONTAINS[c] %@ OR value CONTAINS[c] %@",
            "would like to access",
            "would like to access",
            "would like to use",
            "would like to use"
        )
        return element.staticTexts.matching(promptPredicate).firstMatch.exists
    }

    private func playAudioFixture(at path: String, sample: (() -> Void)? = nil) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.standardError = errorPipe
        let playbackDeviceIndex = e2eConfigValue(
            fileName: "livenotes-e2e-playback-device-index.txt",
            fallback: ""
        )
        if playbackDeviceIndex.isEmpty {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            process.arguments = [path]
        } else {
            let ffmpegPath = e2eConfigValue(
                fileName: "livenotes-e2e-ffmpeg-path.txt",
                fallback: "/opt/homebrew/bin/ffmpeg"
            )
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = [
                "-hide_banner",
                "-loglevel", "error",
                "-i", path,
                "-vn",
                "-f", "audiotoolbox",
                "-audio_device_index", playbackDeviceIndex,
                "-"
            ]
        }
        let duration = try audioDurationSeconds(at: path)
        try process.run()
        let deadline = Date().addingTimeInterval(duration + 3)
        while process.isRunning, Date() < deadline {
            sample?()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return
        }
        let errorOutput = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errorOutput)
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

    private func temporaryArtifactsRoot() -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LiveNotesArtifacts-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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

    private func waitForFile(at path: String, contains expectedText: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if file(at: path, contains: expectedText) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return file(at: path, contains: expectedText)
    }

    private func waitForExport(forStorePath storePath: String, containing expectedText: String, timeout: TimeInterval) -> Bool {
        let exportDirectory = URL(fileURLWithPath: storePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Exports", isDirectory: true)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exportedMarkdown(in: exportDirectory, contains: expectedText) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return exportedMarkdown(in: exportDirectory, contains: expectedText)
    }

    private func waitForAudioFilePath(forStorePath storePath: String, timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var path = firstAudioFilePath(forStorePath: storePath)
        while Date() < deadline {
            if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                return path
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            path = firstAudioFilePath(forStorePath: storePath)
        }
        return path
    }

    private func waitForAppToTerminate(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !app.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !app.exists
    }

    private func exportedMarkdown(in directory: URL, contains expectedText: String) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }
        return files
            .filter { $0.pathExtension == "md" }
            .contains { file(at: $0.path, contains: expectedText) }
    }

    private func normalizedSpeechText(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    private func transcriptTexts(forSessionID id: String? = nil, storePath: String) -> [String] {
        transcriptRows(forSessionID: id, storePath: storePath).compactMap { $0["text"] as? String }
    }

    private func transcriptRows(forSessionID id: String? = nil, storePath: String) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: storePath)),
              let sessions = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let session = sessions.first(where: { id == nil || $0["id"] as? String == id }),
              let transcript = session["transcript"] as? [[String: Any]] else {
            return []
        }
        return transcript
    }

    private func firstAudioFilePath(forStorePath storePath: String) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: storePath)),
              let sessions = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let relativePath = sessions.compactMap({ $0["audioFileName"] as? String }).first else {
            return ""
        }
        return URL(fileURLWithPath: storePath)
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
            .path
    }

    private func fileSize(at path: String) -> Int {
        (try? FileManager.default
            .attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    }

    private func audioFileIsDecodable(at path: String) -> Bool {
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            return file.length > 0
                && file.processingFormat.channelCount > 0
                && file.processingFormat.sampleRate > 0
        } catch {
            return false
        }
    }

    private func audioDurationSeconds(at path: String) throws -> Double {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        return Double(file.length) / max(file.processingFormat.sampleRate, 1)
    }

    private func audioRMSLevel(at path: String) throws -> Float {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let chunkSize = AVAudioFrameCount(4096)
        var sumSquares: Double = 0
        var sampleCount = 0
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let frameCount = AVAudioFrameCount(min(Int64(chunkSize), remaining))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: frameCount
            ) else {
                break
            }
            try file.read(into: buffer, frameCount: frameCount)
            guard let channels = buffer.floatChannelData else {
                continue
            }
            for channelIndex in 0..<Int(buffer.format.channelCount) {
                let channel = channels[channelIndex]
                for frameIndex in 0..<Int(buffer.frameLength) {
                    let sample = Double(channel[frameIndex])
                    sumSquares += sample * sample
                    sampleCount += 1
                }
            }
        }
        guard sampleCount > 0 else { return 0 }
        return Float(sqrt(sumSquares / Double(sampleCount)))
    }

    private func audioDirectoryHasFiles(forStorePath storePath: String) -> Bool {
        let audioDirectory = URL(fileURLWithPath: storePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Audio", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }
        return !files.isEmpty
    }
}

private enum UITestText {
    static let livePreviewEnglish = "We are checking the audio and confirming the transcript is clear."

    static let claritySentence = text([
        0x8BF4, 0x8BDD, 0x8005, 0x91CD, 0x590D, 0x4E86, 0x5173,
        0x952E, 0x53E5, 0x5B50, 0xFF0C, 0x4EE5, 0x4FBF, 0x542C,
        0x6E05, 0x3002
    ])

    static let livePreview = text([
        0x6211, 0x4EEC, 0x6B63, 0x5728, 0x68C0, 0x67E5, 0x97F3,
        0x9891, 0xFF0C, 0x5E76, 0x786E, 0x8BA4, 0x8F6C, 0x5199,
        0x5185, 0x5BB9, 0x6E05, 0x6670, 0x3002
    ])

    private static func text(_ scalars: [UInt32]) -> String {
        String(String.UnicodeScalarView(scalars.compactMap(UnicodeScalar.init)))
    }
}

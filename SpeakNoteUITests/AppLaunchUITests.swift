import XCTest

@MainActor
final class AppLaunchUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testAppLaunchesWithMainWindow() {
    let app = makeApplication()
    app.launch()

    XCTAssertTrue(app.windows["SpeakNote"].waitForExistence(timeout: 5))
  }

  func testFirstRunOnboardingExplainsPermissionsProgressively() {
    let app = makeApplication()
    app.launch()

    XCTAssertTrue(app.staticTexts["Privacy and Storage"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts["SpeakNote has no analytics or advertising tracking."]
        .exists
    )

    app.buttons["Continue"].click()
    XCTAssertTrue(app.staticTexts["Microphone"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.buttons["Request Microphone"].exists)

    app.buttons["Continue"].click()
    XCTAssertTrue(
      app.staticTexts["Global Shortcut and Paste"].waitForExistence(timeout: 2)
    )
    XCTAssertTrue(app.buttons["Request Input Monitoring"].exists)
    XCTAssertTrue(app.buttons["Request Accessibility"].exists)

    app.buttons["Continue"].click()
    XCTAssertTrue(
      app.staticTexts["Optional Local Transcription"].waitForExistence(timeout: 2)
    )
    XCTAssertTrue(app.buttons["Finish"].exists)
    app.buttons["Finish"].click()
    XCTAssertTrue(app.buttons["Start Dictation"].waitForExistence(timeout: 2))
  }

  func testInvalidStorageRootShowsRecoverableStartupFailure() throws {
    let invalidRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpeakNote-invalid-root-\(UUID().uuidString)")
    try Data("not a directory".utf8).write(to: invalidRoot, options: .atomic)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: invalidRoot)
    }

    let app = makeApplication(storageRoot: invalidRoot)
    app.launch()

    XCTAssertTrue(app.windows["SpeakNote"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts["SpeakNote Couldn't Start"].waitForExistence(timeout: 5)
    )
    XCTAssertTrue(app.buttons["Try Again"].exists)
    XCTAssertTrue(app.buttons["Quit SpeakNote"].exists)
    XCTAssertNotEqual(app.state, .notRunning)
  }

  private func makeApplication(storageRoot: URL? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)"]
    app.launchEnvironment["SPEAKNOTE_UI_TEST_SETTINGS_SUITE"] =
      "com.nc8.SpeakNote.UITests.\(UUID().uuidString)"
    if let storageRoot {
      app.launchEnvironment["SPEAKNOTE_UI_TEST_STORAGE_ROOT"] = storageRoot.path
    }
    return app
  }
}

import AppKit
import XCTest

@testable import SpeakNote

@MainActor
final class SecurityAndLifecycleTests: XCTestCase {
  func testSecurityLogEventsUseFixedMachineIdentifiers() {
    XCTAssertEqual(
      SecureLogEvent.keychainReadFailed.rawValue,
      "keychain_read_failed"
    )
    XCTAssertFalse(SecureLogEvent.keychainReadFailed.rawValue.contains(" "))
  }

  func testClosingLastWindowDoesNotTerminateApplication() {
    let delegate = AppDelegate()

    XCTAssertFalse(
      delegate.applicationShouldTerminateAfterLastWindowClosed(
        NSApplication.shared
      )
    )
  }

  func testWorkspaceSleepInvokesDurableInterruptionHandler() async {
    let delegate = AppDelegate()
    let invoked = expectation(description: "sleep handler")
    delegate.sleepHandler = {
      invoked.fulfill()
    }
    delegate.applicationDidFinishLaunching(
      Notification(name: NSApplication.didFinishLaunchingNotification)
    )

    NSWorkspace.shared.notificationCenter.post(
      name: NSWorkspace.willSleepNotification,
      object: nil
    )

    await fulfillment(of: [invoked], timeout: 1)
    delegate.applicationWillTerminate(
      Notification(name: NSApplication.willTerminateNotification)
    )
  }
}

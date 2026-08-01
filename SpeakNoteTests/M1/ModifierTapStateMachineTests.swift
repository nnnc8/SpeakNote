import XCTest

@testable import SpeakNote

final class ModifierTapStateMachineTests: XCTestCase {
  func testTriggersOnlyOnValidRelease() {
    var machine = ModifierTapStateMachine()

    XCTAssertFalse(
      machine.handle(
        .flagsChanged(
          keyCode: 61,
          isPressed: true,
          hasOtherModifiers: false,
          timestamp: 1
        )))
    XCTAssertTrue(
      machine.handle(
        .flagsChanged(
          keyCode: 61,
          isPressed: false,
          hasOtherModifiers: false,
          timestamp: 1.1
        )))
  }

  func testRejectsTooShortTooLongAndCombinedPresses() {
    var machine = ModifierTapStateMachine()

    XCTAssertFalse(
      machine.handle(
        .flagsChanged(
          keyCode: 61,
          isPressed: true,
          hasOtherModifiers: false,
          timestamp: 1
        )))
    XCTAssertFalse(
      machine.handle(
        .flagsChanged(
          keyCode: 61,
          isPressed: false,
          hasOtherModifiers: false,
          timestamp: 1.01
        )))

    XCTAssertFalse(
      machine.handle(
        .flagsChanged(
          keyCode: 61,
          isPressed: true,
          hasOtherModifiers: false,
          timestamp: 2
        )))
    XCTAssertFalse(
      machine.handle(
        .flagsChanged(
          keyCode: 61,
          isPressed: false,
          hasOtherModifiers: false,
          timestamp: 2.8
        )))

    XCTAssertFalse(
      machine.handle(
        .flagsChanged(
          keyCode: 61,
          isPressed: true,
          hasOtherModifiers: true,
          timestamp: 3
        )))
    XCTAssertFalse(
      machine.handle(
        .flagsChanged(
          keyCode: 61,
          isPressed: false,
          hasOtherModifiers: false,
          timestamp: 3.1
        )))
  }

  func testOtherKeyDisarmsAndDebounceSuppressesSecondTap() {
    var machine = ModifierTapStateMachine()

    _ = machine.handle(
      .flagsChanged(
        keyCode: 61,
        isPressed: true,
        hasOtherModifiers: false,
        timestamp: 1
      ))
    _ = machine.handle(.otherKeyActivity(timestamp: 1.05))
    XCTAssertFalse(
      machine.handle(
        .flagsChanged(
          keyCode: 61,
          isPressed: false,
          hasOtherModifiers: false,
          timestamp: 1.1
        )))

    _ = machine.handle(
      .flagsChanged(
        keyCode: 61,
        isPressed: true,
        hasOtherModifiers: false,
        timestamp: 2
      ))
    XCTAssertTrue(
      machine.handle(
        .flagsChanged(
          keyCode: 61,
          isPressed: false,
          hasOtherModifiers: false,
          timestamp: 2.1
        )))
    _ = machine.handle(
      .flagsChanged(
        keyCode: 61,
        isPressed: true,
        hasOtherModifiers: false,
        timestamp: 2.15
      ))
    XCTAssertFalse(
      machine.handle(
        .flagsChanged(
          keyCode: 61,
          isPressed: false,
          hasOtherModifiers: false,
          timestamp: 2.25
        )))
  }

  func testResetClearsAnArmedPress() {
    var machine = ModifierTapStateMachine()
    _ = machine.handle(
      .flagsChanged(
        keyCode: 61,
        isPressed: true,
        hasOtherModifiers: false,
        timestamp: 1
      ))

    machine.reset()
    XCTAssertFalse(
      machine.handle(
        .flagsChanged(
          keyCode: 61,
          isPressed: false,
          hasOtherModifiers: false,
          timestamp: 1.1
        )))
  }
}

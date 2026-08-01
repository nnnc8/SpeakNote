import XCTest

@testable import SpeakNote

@MainActor
final class PermissionCenterTests: XCTestCase {
  func testInitializationOnlyPreflightsAndExplicitRequestStaysSeparated() async {
    let system = FakePermissionSystem(
      snapshot: PermissionSnapshot(
        microphone: .notDetermined,
        listenEvents: .notGranted,
        postEvents: .granted,
        speechRecognition: .notDetermined
      )
    )
    let center = PermissionCenter(system: system)

    XCTAssertEqual(center.snapshot.microphone, .notDetermined)
    XCTAssertEqual(center.snapshot.listenEvents, .notGranted)
    XCTAssertEqual(center.snapshot.postEvents, .granted)
    XCTAssertEqual(center.snapshot.speechRecognition, .notDetermined)
    XCTAssertTrue(system.requests.isEmpty)

    await center.request(.listenEvents)

    XCTAssertEqual(system.requests, [.listenEvents])
    XCTAssertEqual(center.snapshot.listenEvents, .granted)
    XCTAssertEqual(center.snapshot.microphone, .notDetermined)
    XCTAssertEqual(center.snapshot.postEvents, .granted)

    await center.request(.speechRecognition)

    XCTAssertEqual(
      system.requests,
      [.listenEvents, .speechRecognition]
    )
    XCTAssertEqual(center.snapshot.speechRecognition, .granted)
  }

  func testRefreshAndSettingsRoutingUseInjectedBoundary() {
    let system = FakePermissionSystem(
      snapshot: PermissionSnapshot(
        microphone: .notGranted,
        listenEvents: .notGranted,
        postEvents: .notGranted,
        speechRecognition: .notGranted
      )
    )
    let center = PermissionCenter(system: system)
    system.snapshot.microphone = .granted

    center.refresh()
    center.openSystemSettings(for: .microphone)

    XCTAssertEqual(center.snapshot.microphone, .granted)
    XCTAssertEqual(system.openedSettings, [.microphone])
    XCTAssertTrue(system.requests.isEmpty)
  }
}

@MainActor
private final class FakePermissionSystem: PermissionSystemAccessing {
  var snapshot: PermissionSnapshot
  private(set) var requests: [PermissionKind] = []
  private(set) var openedSettings: [PermissionKind] = []

  init(snapshot: PermissionSnapshot) {
    self.snapshot = snapshot
  }

  func status(for kind: PermissionKind) -> PermissionStatus {
    snapshot[kind]
  }

  func request(_ kind: PermissionKind) async {
    requests.append(kind)
    switch kind {
    case .microphone:
      snapshot.microphone = .granted
    case .listenEvents:
      snapshot.listenEvents = .granted
    case .postEvents:
      snapshot.postEvents = .granted
    case .speechRecognition:
      snapshot.speechRecognition = .granted
    }
  }

  func openSystemSettings(for kind: PermissionKind) {
    openedSettings.append(kind)
  }
}

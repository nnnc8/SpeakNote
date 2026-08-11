import Dispatch
import Speech
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

  func testSpeechAuthorizationCallbackMayCompleteOffMainActor() async {
    let access = SystemPermissionAccess(
      speechAuthorizationRequester: BackgroundSpeechAuthorizationRequester()
    )

    await access.request(.speechRecognition)
  }

  func testConcurrentRequestsForOnePermissionUseOneSystemRequest() async {
    let system = FakePermissionSystem(
      snapshot: PermissionSnapshot(
        microphone: .notDetermined,
        listenEvents: .notGranted,
        postEvents: .notGranted,
        speechRecognition: .notDetermined
      )
    )
    system.suspendRequests = true
    let started = expectation(description: "request started")
    system.onRequest = { started.fulfill() }
    let center = PermissionCenter(system: system)

    let first = Task { @MainActor in
      await center.request(.microphone)
    }
    await fulfillment(of: [started], timeout: 1)

    let second = Task { @MainActor in
      await center.request(.microphone)
    }
    await Task.yield()

    XCTAssertEqual(system.requests, [.microphone])
    system.resumeSuspendedRequest?()
    await first.value
    await second.value

    XCTAssertTrue(system.requests.count == 1)
    XCTAssertFalse(center.isRequesting(.microphone))
    XCTAssertEqual(center.snapshot.microphone, .granted)
  }
}

@MainActor
private final class FakePermissionSystem: PermissionSystemAccessing {
  var snapshot: PermissionSnapshot
  var suspendRequests = false
  var onRequest: (() -> Void)?
  var resumeSuspendedRequest: (() -> Void)?
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
    onRequest?()
    if suspendRequests {
      await withCheckedContinuation { continuation in
        resumeSuspendedRequest = { continuation.resume() }
      }
    }
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

private struct BackgroundSpeechAuthorizationRequester:
  SpeechAuthorizationRequesting
{
  func requestAuthorization(
    _ handler: @escaping @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void
  ) {
    DispatchQueue.global(qos: .utility).async {
      handler(.authorized)
    }
  }
}

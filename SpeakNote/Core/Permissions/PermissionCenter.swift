import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Speech

enum PermissionKind: String, CaseIterable, Hashable, Identifiable, Sendable {
  case microphone
  case listenEvents
  case postEvents
  case speechRecognition

  var id: Self { self }

  var title: String {
    switch self {
    case .microphone:
      String(localized: "Microphone")
    case .listenEvents:
      String(localized: "Input Monitoring")
    case .postEvents:
      String(localized: "Accessibility")
    case .speechRecognition:
      String(localized: "Speech Recognition")
    }
  }
}

enum PermissionStatus: String, Equatable, Sendable {
  case notDetermined
  case notGranted
  case granted

  var title: String {
    switch self {
    case .notDetermined:
      String(localized: "Not requested")
    case .notGranted:
      String(localized: "Not granted")
    case .granted:
      String(localized: "Granted")
    }
  }
}

struct PermissionSnapshot: Equatable, Sendable {
  var microphone: PermissionStatus
  var listenEvents: PermissionStatus
  var postEvents: PermissionStatus
  var speechRecognition: PermissionStatus = .notDetermined

  subscript(_ kind: PermissionKind) -> PermissionStatus {
    switch kind {
    case .microphone:
      microphone
    case .listenEvents:
      listenEvents
    case .postEvents:
      postEvents
    case .speechRecognition:
      speechRecognition
    }
  }
}

@MainActor
protocol PermissionSystemAccessing: AnyObject {
  func status(for kind: PermissionKind) -> PermissionStatus
  func request(_ kind: PermissionKind) async
  func openSystemSettings(for kind: PermissionKind)
}

@MainActor
final class SystemPermissionAccess: PermissionSystemAccessing {
  func status(for kind: PermissionKind) -> PermissionStatus {
    switch kind {
    case .microphone:
      switch AVCaptureDevice.authorizationStatus(for: .audio) {
      case .authorized:
        .granted
      case .notDetermined:
        .notDetermined
      case .denied, .restricted:
        .notGranted
      @unknown default:
        .notGranted
      }
    case .listenEvents:
      CGPreflightListenEventAccess() ? .granted : .notGranted
    case .postEvents:
      CGPreflightPostEventAccess() ? .granted : .notGranted
    case .speechRecognition:
      switch SFSpeechRecognizer.authorizationStatus() {
      case .authorized:
        .granted
      case .notDetermined:
        .notDetermined
      case .denied, .restricted:
        .notGranted
      @unknown default:
        .notGranted
      }
    }
  }

  func request(_ kind: PermissionKind) async {
    switch kind {
    case .microphone:
      _ = await AVCaptureDevice.requestAccess(for: .audio)
    case .listenEvents:
      _ = CGRequestListenEventAccess()
    case .postEvents:
      _ = CGRequestPostEventAccess()
    case .speechRecognition:
      await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { _ in
          continuation.resume()
        }
      }
    }
  }

  func openSystemSettings(for kind: PermissionKind) {
    let pane: String
    switch kind {
    case .microphone:
      pane = "Privacy_Microphone"
    case .listenEvents:
      pane = "Privacy_ListenEvent"
    case .postEvents:
      pane = "Privacy_Accessibility"
    case .speechRecognition:
      pane = "Privacy_SpeechRecognition"
    }

    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
      )
    else {
      return
    }
    NSWorkspace.shared.open(url)
  }
}

@MainActor
final class PermissionCenter: ObservableObject {
  @Published private(set) var snapshot: PermissionSnapshot
  private let system: any PermissionSystemAccessing

  init(system: any PermissionSystemAccessing) {
    self.system = system
    snapshot = Self.readSnapshot(from: system)
  }

  convenience init() {
    self.init(system: SystemPermissionAccess())
  }

  func refresh() {
    snapshot = Self.readSnapshot(from: system)
  }

  func request(_ kind: PermissionKind) async {
    await system.request(kind)
    refresh()
  }

  func openSystemSettings(for kind: PermissionKind) {
    system.openSystemSettings(for: kind)
  }

  private static func readSnapshot(
    from system: any PermissionSystemAccessing
  ) -> PermissionSnapshot {
    PermissionSnapshot(
      microphone: system.status(for: .microphone),
      listenEvents: system.status(for: .listenEvents),
      postEvents: system.status(for: .postEvents),
      speechRecognition: system.status(for: .speechRecognition)
    )
  }
}

import Foundation

protocol AudioRecorder: Sendable {
  func start() async throws
  func stop() async throws -> URL
  func cancel() async
}

enum AudioRecorderError: Error, Equatable, Sendable {
  case alreadyRecording
  case notRecording
  case permissionDenied
  case invalidInputFormat
  case bufferOverrun
  case maximumDurationExceeded
  case cancelled
  case recordingFailed(String)
  case conversionFailed(String)
}

extension AudioRecorderError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .alreadyRecording:
      String(localized: "A recording is already in progress.")
    case .notRecording:
      String(localized: "There is no active recording.")
    case .permissionDenied:
      String(localized: "Microphone access is required to dictate.")
    case .invalidInputFormat:
      String(localized: "The selected microphone does not provide a usable audio format.")
    case .bufferOverrun:
      String(
        localized:
          "Audio could not be written quickly enough. The recording was cancelled."
      )
    case .maximumDurationExceeded:
      String(localized: "Quick dictation is limited to five minutes.")
    case .cancelled:
      String(localized: "Recording was cancelled.")
    case .recordingFailed(let message):
      String(localized: "Recording failed: \(message)")
    case .conversionFailed(let message):
      String(localized: "Audio conversion failed: \(message)")
    }
  }
}

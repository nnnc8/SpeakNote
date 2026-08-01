import Foundation
import Speech

actor LegacySpeechRecognizerAdapter: AppleSpeechAdapter {
  func availability(for locale: Locale) async -> SpeechAdapterAvailability {
    let supportedLocale = Self.supportedLocale(equivalentTo: locale)
    let recognizer = supportedLocale.flatMap(SFSpeechRecognizer.init(locale:))
    return SpeechAdapterAvailability(
      authorization: Self.authorizationState,
      isAvailable: recognizer?.isAvailable ?? false,
      supportsLocale: supportedLocale != nil,
      supportsOnDeviceRecognition:
        recognizer?.supportsOnDeviceRecognition ?? false,
      modelAssetState: .notRequired
    )
  }

  func transcribe(
    audioURL: URL,
    locale: Locale,
    duration: TimeInterval
  ) async throws -> Transcript {
    guard duration.isFinite, duration >= 0 else {
      throw AppleTranscriptionError.unavailable(.invalidDuration)
    }
    guard duration < TranscriptionCapabilityResolver.legacyMaximumDuration else {
      throw AppleTranscriptionError.unavailable(
        .legacyDurationLimitExceeded
      )
    }
    guard Self.authorizationState == .authorized else {
      let reason: TranscriptionUnavailableReason =
        Self.authorizationState == .notDetermined
        ? .permissionNotDetermined
        : .permissionDenied
      throw AppleTranscriptionError.unavailable(reason)
    }
    guard let supportedLocale = Self.supportedLocale(equivalentTo: locale) else {
      throw AppleTranscriptionError.unavailable(.unsupportedLocale)
    }
    guard let recognizer = SFSpeechRecognizer(locale: supportedLocale) else {
      throw AppleTranscriptionError.unavailable(.unsupportedLocale)
    }
    guard recognizer.isAvailable else {
      throw AppleTranscriptionError.unavailable(.recognizerUnavailable)
    }
    guard recognizer.supportsOnDeviceRecognition else {
      throw AppleTranscriptionError.unavailable(
        .onDeviceRecognitionUnavailable
      )
    }

    let request = SFSpeechURLRecognitionRequest(url: audioURL)
    request.shouldReportPartialResults = false
    request.requiresOnDeviceRecognition = true
    request.addsPunctuation = true

    let operation = LegacyRecognitionOperation()
    do {
      return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
          operation.setContinuation(continuation)
          let task = recognizer.recognitionTask(with: request) { result, error in
            if let result, result.isFinal {
              operation.finish(
                Self.makeTranscript(
                  from: result.bestTranscription,
                  locale: supportedLocale
                )
              )
            } else if error != nil {
              operation.finish(.failure(.recognitionFailed))
            }
          }
          operation.install(task)
        }
      } onCancel: {
        operation.cancel()
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as AppleTranscriptionError {
      throw error
    } catch {
      throw AppleTranscriptionError.recognitionFailed
    }
  }

  private static var authorizationState: SpeechAuthorizationState {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .notDetermined:
      .notDetermined
    case .denied:
      .denied
    case .restricted:
      .restricted
    case .authorized:
      .authorized
    @unknown default:
      .denied
    }
  }

  private static func supportedLocale(equivalentTo locale: Locale) -> Locale? {
    let identifier = normalizedIdentifier(locale.identifier)
    return SFSpeechRecognizer.supportedLocales().first {
      normalizedIdentifier($0.identifier) == identifier
    }
  }

  private static func normalizedIdentifier(_ identifier: String) -> String {
    identifier.replacingOccurrences(of: "_", with: "-").lowercased()
  }

  private static func makeTranscript(
    from transcription: SFTranscription,
    locale: Locale
  ) -> Result<Transcript, AppleTranscriptionError> {
    let text = transcription.formattedString
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      return .failure(.invalidResult)
    }

    var segments: [TranscriptSegment] = []
    for speechSegment in transcription.segments {
      let startTime = speechSegment.timestamp
      let segmentDuration = speechSegment.duration
      guard
        startTime.isFinite,
        segmentDuration.isFinite,
        startTime >= 0,
        segmentDuration >= 0
      else {
        return .failure(.invalidResult)
      }
      let segmentText = speechSegment.substring
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !segmentText.isEmpty else { continue }
      segments.append(
        TranscriptSegment(
          startTime: startTime,
          endTime: startTime + segmentDuration,
          text: segmentText,
          detectedLanguage: locale.identifier
        )
      )
    }
    guard !segments.isEmpty else {
      return .failure(.invalidResult)
    }
    return .success(
      Transcript(
        text: text,
        segments: segments,
        detectedLanguage: locale.identifier
      )
    )
  }
}

private final class LegacyRecognitionOperation: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation:
    CheckedContinuation<Transcript, any Error>?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var isFinished = false

  func setContinuation(
    _ continuation: CheckedContinuation<Transcript, any Error>
  ) {
    lock.lock()
    if isFinished {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func install(_ task: SFSpeechRecognitionTask) {
    lock.lock()
    if isFinished {
      lock.unlock()
      task.cancel()
      return
    }
    recognitionTask = task
    lock.unlock()
  }

  func finish(
    _ result: Result<Transcript, AppleTranscriptionError>
  ) {
    lock.lock()
    guard !isFinished else {
      lock.unlock()
      return
    }
    isFinished = true
    let continuation = continuation
    self.continuation = nil
    recognitionTask = nil
    lock.unlock()

    continuation?.resume(with: result.mapError { $0 as any Error })
  }

  func cancel() {
    lock.lock()
    guard !isFinished else {
      lock.unlock()
      return
    }
    isFinished = true
    let continuation = continuation
    let recognitionTask = recognitionTask
    self.continuation = nil
    self.recognitionTask = nil
    lock.unlock()

    recognitionTask?.cancel()
    continuation?.resume(throwing: CancellationError())
  }
}

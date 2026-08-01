import Foundation
import XCTest

@testable import SpeakNote

final class AppleTranscriptionEngineTests: XCTestCase {
  func testMacOS26UsesAnalyzerAndPreservesSharedTranscriptTimestamps()
    async throws
  {
    let expected = Transcript(
      text: "local speech",
      segments: [
        TranscriptSegment(
          startTime: 0.25,
          endTime: 1.75,
          text: "local speech",
          detectedLanguage: "en-US"
        )
      ],
      detectedLanguage: "en-US"
    )
    let analyzer = M6MockSpeechAdapter(
      availability: analyzerAvailability(),
      outcome: .success(expected)
    )
    let legacy = M6MockSpeechAdapter(
      availability: legacyAvailability(),
      outcome: .failure(.recognitionFailed)
    )
    let engine = AppleTranscriptionEngine(
      speechAnalyzer: analyzer,
      legacyRecognizer: legacy,
      durationLoader: M6DurationLoader(duration: 90),
      macOSMajorVersion: 26
    )

    let transcript = try await engine.transcribe(
      audioURL: URL(fileURLWithPath: "/tmp/m6-analyzer.m4a"),
      configuration: TranscriptionConfiguration(languageCode: "en-US")
    )

    XCTAssertEqual(transcript, expected)
    let analyzerCalls = await analyzer.transcriptionCallCount
    let legacyCalls = await legacy.transcriptionCallCount
    XCTAssertEqual(analyzerCalls, 1)
    XCTAssertEqual(legacyCalls, 0)
  }

  func testMacOS15UsesLegacyAdapter() async throws {
    let expected = Transcript(text: "legacy local")
    let analyzer = M6MockSpeechAdapter(
      availability: analyzerAvailability(),
      outcome: .failure(.recognitionFailed)
    )
    let legacy = M6MockSpeechAdapter(
      availability: legacyAvailability(),
      outcome: .success(expected)
    )
    let engine = AppleTranscriptionEngine(
      speechAnalyzer: analyzer,
      legacyRecognizer: legacy,
      durationLoader: M6DurationLoader(duration: 54.9),
      macOSMajorVersion: 15
    )

    let transcript = try await engine.transcribe(
      audioURL: URL(fileURLWithPath: "/tmp/m6-legacy.m4a"),
      configuration: TranscriptionConfiguration(languageCode: "en-US")
    )

    XCTAssertEqual(transcript, expected)
    let analyzerCalls = await analyzer.transcriptionCallCount
    let legacyCalls = await legacy.transcriptionCallCount
    XCTAssertEqual(analyzerCalls, 0)
    XCTAssertEqual(legacyCalls, 1)
  }

  func testAnalyzerFailureNeverSilentlyFallsBackToLegacy() async throws {
    let analyzer = M6MockSpeechAdapter(
      availability: analyzerAvailability(modelAssetState: .missing),
      outcome: .failure(.recognitionFailed)
    )
    let legacy = M6MockSpeechAdapter(
      availability: legacyAvailability(),
      outcome: .success(Transcript(text: "must not be returned"))
    )
    let engine = AppleTranscriptionEngine(
      speechAnalyzer: analyzer,
      legacyRecognizer: legacy,
      durationLoader: M6DurationLoader(duration: 5),
      macOSMajorVersion: 26
    )

    do {
      _ = try await engine.transcribe(
        audioURL: URL(fileURLWithPath: "/tmp/m6-missing-model.m4a"),
        configuration: TranscriptionConfiguration(languageCode: "en-US")
      )
      XCTFail("Expected missing model")
    } catch {
      XCTAssertEqual(
        error as? AppleTranscriptionError,
        .unavailable(.modelMissing)
      )
    }
    let analyzerCalls = await analyzer.transcriptionCallCount
    let legacyCalls = await legacy.transcriptionCallCount
    XCTAssertEqual(analyzerCalls, 0)
    XCTAssertEqual(legacyCalls, 0)
  }

  func testPermissionDeniedAndRecognizerUnavailableAreTyped() async throws {
    let permissionDenied = M6MockSpeechAdapter(
      availability: legacyAvailability(authorization: .denied),
      outcome: .failure(.recognitionFailed)
    )
    let deniedEngine = AppleTranscriptionEngine(
      speechAnalyzer: nil,
      legacyRecognizer: permissionDenied,
      durationLoader: M6DurationLoader(duration: 5),
      macOSMajorVersion: 15
    )
    let unavailable = M6MockSpeechAdapter(
      availability: legacyAvailability(isAvailable: false),
      outcome: .failure(.recognitionFailed)
    )
    let unavailableEngine = AppleTranscriptionEngine(
      speechAnalyzer: nil,
      legacyRecognizer: unavailable,
      durationLoader: M6DurationLoader(duration: 5),
      macOSMajorVersion: 15
    )

    await assertError(
      from: deniedEngine,
      equals: .unavailable(.permissionDenied)
    )
    await assertError(
      from: unavailableEngine,
      equals: .unavailable(.recognizerUnavailable)
    )
  }

  func testEngineRequiresConsentBeforeLocalToCloudFallback() {
    let legacy = M6MockSpeechAdapter(
      availability: legacyAvailability(),
      outcome: .failure(.recognitionFailed)
    )
    let engine = AppleTranscriptionEngine(
      speechAnalyzer: nil,
      legacyRecognizer: legacy,
      macOSMajorVersion: 15
    )

    XCTAssertEqual(engine.fallbackPolicy, .askBeforeCrossingBoundary)
    XCTAssertEqual(
      engine.fallbackDecision(to: .cloud),
      .requiresConsent
    )
    XCTAssertEqual(
      engine.fallbackDecision(to: .cloud, userConsented: true),
      .allowed
    )
  }

  private func assertError(
    from engine: AppleTranscriptionEngine,
    equals expected: AppleTranscriptionError
  ) async {
    do {
      _ = try await engine.transcribe(
        audioURL: URL(fileURLWithPath: "/tmp/m6-error.m4a"),
        configuration: TranscriptionConfiguration(languageCode: "en-US")
      )
      XCTFail("Expected \(expected)")
    } catch {
      XCTAssertEqual(error as? AppleTranscriptionError, expected)
    }
  }

  private func analyzerAvailability(
    modelAssetState: SpeechModelAssetState = .installed
  ) -> SpeechAdapterAvailability {
    SpeechAdapterAvailability(
      authorization: .authorized,
      isAvailable: true,
      supportsLocale: true,
      supportsOnDeviceRecognition: true,
      modelAssetState: modelAssetState
    )
  }

  private func legacyAvailability(
    authorization: SpeechAuthorizationState = .authorized,
    isAvailable: Bool = true
  ) -> SpeechAdapterAvailability {
    SpeechAdapterAvailability(
      authorization: authorization,
      isAvailable: isAvailable,
      supportsLocale: true,
      supportsOnDeviceRecognition: true,
      modelAssetState: .notRequired
    )
  }
}

private struct M6DurationLoader: AudioDurationLoading {
  let duration: TimeInterval

  func duration(of _: URL) async throws -> TimeInterval {
    duration
  }
}

private actor M6MockSpeechAdapter: AppleSpeechAdapter {
  private let adapterAvailability: SpeechAdapterAvailability
  private let outcome: Result<Transcript, AppleTranscriptionError>
  private(set) var transcriptionCallCount = 0

  init(
    availability: SpeechAdapterAvailability,
    outcome: Result<Transcript, AppleTranscriptionError>
  ) {
    adapterAvailability = availability
    self.outcome = outcome
  }

  func availability(for _: Locale) async -> SpeechAdapterAvailability {
    adapterAvailability
  }

  func transcribe(
    audioURL _: URL,
    locale _: Locale,
    duration _: TimeInterval
  ) async throws -> Transcript {
    transcriptionCallCount += 1
    return try outcome.get()
  }
}

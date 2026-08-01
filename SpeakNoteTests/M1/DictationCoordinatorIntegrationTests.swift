import Foundation
import XCTest

@testable import SpeakNote

@MainActor
final class DictationCoordinatorIntegrationTests: XCTestCase {
  func testRunsInjectedRecorderTranscriberAndInserterEndToEnd() async throws {
    let audioURL = try makeTemporaryAudio()
    defer { try? FileManager.default.removeItem(at: audioURL) }
    let recorder = CoordinatorFakeRecorder(outputURL: audioURL)
    let transcriber = CoordinatorFakeTranscriber(
      transcript: Transcript(text: "hello from test")
    )
    let inserter = CoordinatorFakeInserter(result: .inserted)
    let settings = FakeSettingsRepository(
      settings: AppSettings(
        transcriptionProviderID: .groq,
        transcriptionModelID: GroqTranscriptionModel.largeV3,
        dictationHistoryEnabled: false,
        hasAcknowledgedGroqCloudProcessing: true
      ))
    let coordinator = DictationCoordinator(
      recorder: recorder,
      transcriber: transcriber,
      textProcessor: CoordinatorFakeTextProcessor(),
      historyRepository: try makeHistoryRepository(),
      settingsRepository: settings,
      inserter: inserter,
      manualTextCopier: CoordinatorFakeManualCopier(),
      hud: CoordinatorFakeHUD()
    )

    coordinator.toggle()
    try await waitUntil {
      if case .recording = coordinator.state { return true }
      return false
    }
    coordinator.toggle()
    try await waitUntil {
      coordinator.state == .success(text: "hello from test")
    }

    XCTAssertEqual(inserter.insertedText, "hello from test")
    let capturedModelID = await transcriber.capturedConfiguration?.modelID
    let startCount = await recorder.startCount
    let stopCount = await recorder.stopCount
    XCTAssertEqual(capturedModelID, GroqTranscriptionModel.largeV3)
    XCTAssertEqual(startCount, 1)
    XCTAssertEqual(stopCount, 1)
    try await waitUntil {
      !FileManager.default.fileExists(atPath: audioURL.path)
    }
  }

  func testManualFallbackRetainsTranscriptUntilExplicitCopy() async throws {
    let audioURL = try makeTemporaryAudio()
    defer { try? FileManager.default.removeItem(at: audioURL) }
    let copier = CoordinatorFakeManualCopier()
    let coordinator = DictationCoordinator(
      recorder: CoordinatorFakeRecorder(outputURL: audioURL),
      transcriber: CoordinatorFakeTranscriber(
        transcript: Transcript(text: "recoverable transcript")
      ),
      textProcessor: CoordinatorFakeTextProcessor(),
      historyRepository: try makeHistoryRepository(),
      settingsRepository: FakeSettingsRepository(settings: .dictationTestValue),
      inserter: CoordinatorFakeInserter(
        result: .manualCopyRequired(.secureInputEnabled)
      ),
      manualTextCopier: copier,
      hud: CoordinatorFakeHUD()
    )

    coordinator.toggle()
    try await waitUntil {
      if case .recording = coordinator.state { return true }
      return false
    }
    coordinator.toggle()
    try await waitUntil {
      coordinator.manualCopyText == "recoverable transcript"
    }

    XCTAssertTrue(coordinator.copyManualTranscript())
    XCTAssertEqual(copier.copiedText, "recoverable transcript")
    XCTAssertNil(coordinator.manualCopyText)
    XCTAssertEqual(coordinator.state, .success(text: "recoverable transcript"))
  }

  func testAppButtonModeRecordsWithoutCapturingTargetAndRequiresExplicitCopy()
    async throws
  {
    let audioURL = try makeTemporaryAudio()
    defer { try? FileManager.default.removeItem(at: audioURL) }
    let copier = CoordinatorFakeManualCopier()
    let inserter = CoordinatorFakeInserter(result: .inserted)
    let coordinator = DictationCoordinator(
      recorder: CoordinatorFakeRecorder(outputURL: audioURL),
      transcriber: CoordinatorFakeTranscriber(
        transcript: Transcript(text: "app button transcript")
      ),
      textProcessor: CoordinatorFakeTextProcessor(),
      historyRepository: try makeHistoryRepository(),
      settingsRepository: FakeSettingsRepository(settings: .dictationTestValue),
      inserter: inserter,
      manualTextCopier: copier,
      hud: CoordinatorFakeHUD()
    )

    coordinator.toggleForManualCopy()
    try await waitUntil {
      if case .recording = coordinator.state { return true }
      return false
    }
    coordinator.toggleForManualCopy()
    try await waitUntil {
      coordinator.manualCopyText == "app button transcript"
    }

    XCTAssertEqual(inserter.captureCount, 0)
    XCTAssertNil(inserter.insertedText)
    XCTAssertTrue(coordinator.copyManualTranscript())
    XCTAssertEqual(copier.copiedText, "app button transcript")
  }

  func testInsertionErrorRetainsRecognizedTranscriptForManualCopy() async throws {
    let audioURL = try makeTemporaryAudio()
    defer { try? FileManager.default.removeItem(at: audioURL) }
    let coordinator = DictationCoordinator(
      recorder: CoordinatorFakeRecorder(outputURL: audioURL),
      transcriber: CoordinatorFakeTranscriber(
        transcript: Transcript(text: "still recoverable")
      ),
      textProcessor: CoordinatorFakeTextProcessor(),
      historyRepository: try makeHistoryRepository(),
      settingsRepository: FakeSettingsRepository(settings: .dictationTestValue),
      inserter: CoordinatorThrowingInserter(),
      manualTextCopier: CoordinatorFakeManualCopier(),
      hud: CoordinatorFakeHUD()
    )

    coordinator.toggle()
    try await waitUntil {
      if case .recording = coordinator.state { return true }
      return false
    }
    coordinator.toggle()
    try await waitUntil {
      coordinator.manualCopyText == "still recoverable"
    }

    guard case .failure(let message) = coordinator.state else {
      return XCTFail("Insertion failure must expose manual recovery.")
    }
    let baseMessage = String(
      localized: "Automatic insertion could not be confirmed safely."
    )
    XCTAssertEqual(
      message,
      String(localized: "\(baseMessage) Use “Copy Last Transcript” in SpeakNote.")
    )
    try await waitUntil {
      !FileManager.default.fileExists(atPath: audioURL.path)
    }
  }

  func testEscapeDoesNotChangeTerminalState() async throws {
    let audioURL = try makeTemporaryAudio()
    defer { try? FileManager.default.removeItem(at: audioURL) }
    let coordinator = DictationCoordinator(
      recorder: CoordinatorFakeRecorder(outputURL: audioURL),
      transcriber: CoordinatorFakeTranscriber(
        transcript: Transcript(text: "done")
      ),
      textProcessor: CoordinatorFakeTextProcessor(),
      historyRepository: try makeHistoryRepository(),
      settingsRepository: FakeSettingsRepository(settings: .dictationTestValue),
      inserter: CoordinatorFakeInserter(result: .inserted),
      manualTextCopier: CoordinatorFakeManualCopier(),
      hud: CoordinatorFakeHUD()
    )

    coordinator.toggle()
    try await waitUntil {
      if case .recording = coordinator.state { return true }
      return false
    }
    coordinator.toggle()
    try await waitUntil {
      coordinator.state == .success(text: "done")
    }

    coordinator.cancel()

    XCTAssertEqual(coordinator.state, .success(text: "done"))
  }

  func testShutdownCancelsActiveRecorderAndHidesHUD() async throws {
    let audioURL = try makeTemporaryAudio()
    defer { try? FileManager.default.removeItem(at: audioURL) }
    let recorder = CoordinatorFakeRecorder(outputURL: audioURL)
    let hud = CoordinatorFakeHUD()
    let coordinator = DictationCoordinator(
      recorder: recorder,
      transcriber: CoordinatorFakeTranscriber(
        transcript: Transcript(text: "unused")
      ),
      textProcessor: CoordinatorFakeTextProcessor(),
      historyRepository: try makeHistoryRepository(),
      settingsRepository: FakeSettingsRepository(settings: .dictationTestValue),
      inserter: CoordinatorFakeInserter(result: .inserted),
      manualTextCopier: CoordinatorFakeManualCopier(),
      hud: hud
    )
    coordinator.toggle()
    try await waitUntil {
      if case .recording = coordinator.state { return true }
      return false
    }

    await coordinator.shutdown()
    let cancelCount = await recorder.cancelCount

    XCTAssertEqual(cancelCount, 1)
    XCTAssertEqual(coordinator.state, .cancelled)
    XCTAssertEqual(hud.hideCount, 1)
  }

  func testImmediateRestartWaitsForCancellationToJoin() async throws {
    let recorder = DelayedCancelRecorder()
    let coordinator = DictationCoordinator(
      recorder: recorder,
      transcriber: CoordinatorFakeTranscriber(
        transcript: Transcript(text: "unused")
      ),
      textProcessor: CoordinatorFakeTextProcessor(),
      historyRepository: try makeHistoryRepository(),
      settingsRepository: FakeSettingsRepository(settings: .dictationTestValue),
      inserter: CoordinatorFakeInserter(result: .inserted),
      manualTextCopier: CoordinatorFakeManualCopier(),
      hud: CoordinatorFakeHUD()
    )
    coordinator.toggle()
    try await waitUntil {
      if case .recording = coordinator.state { return true }
      return false
    }

    coordinator.cancel()
    XCTAssertEqual(coordinator.state, .cancelling)
    coordinator.toggle()
    let countWhileCancelling = await recorder.startCount
    XCTAssertEqual(countWhileCancelling, 1)

    await recorder.releaseCancellation()
    try await waitUntil {
      coordinator.state == .cancelled
    }
    coordinator.toggle()
    try await waitUntil {
      if case .recording = coordinator.state { return true }
      return false
    }
    let countAfterCancellation = await recorder.startCount
    XCTAssertEqual(countAfterCancellation, 2)

    await coordinator.shutdown()
  }

  func testM2PersistsRawBeforeProcessingAndAppendsProcessedRun() async throws {
    let audioURL = try makeTemporaryAudio()
    defer { try? FileManager.default.removeItem(at: audioURL) }
    let repository = try makeHistoryRepository()
    let transcriptID = UUID()
    let processor = RawFirstAssertingTextProcessor(
      historyRepository: repository,
      output: "Clean output"
    )
    let inserter = CoordinatorFakeInserter(result: .inserted)
    let settings = FakeSettingsRepository(
      settings: AppSettings(
        textProcessingModelID: "fixture-model",
        compressionLevel: .clean,
        dictationHistoryEnabled: true,
        hasAcknowledgedGroqCloudProcessing: true
      )
    )
    let coordinator = DictationCoordinator(
      recorder: CoordinatorFakeRecorder(outputURL: audioURL),
      transcriber: CoordinatorFakeTranscriber(
        transcript: Transcript(
          id: transcriptID,
          text: "raw output",
          detectedLanguage: "en"
        )
      ),
      textProcessor: processor,
      historyRepository: repository,
      settingsRepository: settings,
      inserter: inserter,
      manualTextCopier: CoordinatorFakeManualCopier(),
      hud: CoordinatorFakeHUD()
    )

    coordinator.toggle()
    try await waitUntil {
      if case .recording = coordinator.state { return true }
      return false
    }
    coordinator.toggle()
    try await waitUntil {
      coordinator.state == .success(text: "Clean output")
    }

    let record = try await repository.record(id: transcriptID)
    let runs = try await repository.runs(
      ownerKind: .dictation,
      ownerID: transcriptID
    )
    let observedRawFirst = await processor.observedRawBeforeProcessing
    XCTAssertEqual(record?.rawTranscript, "raw output")
    XCTAssertEqual(inserter.insertedText, "Clean output")
    XCTAssertEqual(runs.map(\.outputText), ["Clean output"])
    XCTAssertTrue(observedRawFirst)
  }

  func testM2ProcessingFailureFallsBackToRawAndKeepsFailedRun() async throws {
    let audioURL = try makeTemporaryAudio()
    defer { try? FileManager.default.removeItem(at: audioURL) }
    let repository = try makeHistoryRepository()
    let transcriptID = UUID()
    let inserter = CoordinatorFakeInserter(result: .inserted)
    let coordinator = DictationCoordinator(
      recorder: CoordinatorFakeRecorder(outputURL: audioURL),
      transcriber: CoordinatorFakeTranscriber(
        transcript: Transcript(id: transcriptID, text: "raw fallback")
      ),
      textProcessor: CoordinatorFailingTextProcessor(),
      historyRepository: repository,
      settingsRepository: FakeSettingsRepository(
        settings: AppSettings(
          compressionLevel: .polished,
          dictationHistoryEnabled: true,
          hasAcknowledgedGroqCloudProcessing: true
        )
      ),
      inserter: inserter,
      manualTextCopier: CoordinatorFakeManualCopier(),
      hud: CoordinatorFakeHUD()
    )

    coordinator.toggle()
    try await waitUntil {
      if case .recording = coordinator.state { return true }
      return false
    }
    coordinator.toggle()
    try await waitUntil {
      coordinator.state == .success(text: "raw fallback")
    }

    let runs = try await repository.runs(
      ownerKind: .dictation,
      ownerID: transcriptID
    )
    XCTAssertEqual(inserter.insertedText, "raw fallback")
    XCTAssertEqual(runs.first?.status, .failed)
    XCTAssertNil(runs.first?.outputText)
  }

  func testCrossBoundaryFallbackRetainsAudioUntilExplicitAcceptance() async throws {
    let audioURL = try makeTemporaryAudio()
    defer { try? FileManager.default.removeItem(at: audioURL) }
    let apple = CoordinatorFakeTranscriber(
      transcript: Transcript(text: "apple should not run")
    )
    let groq = CoordinatorFakeTranscriber(
      transcript: Transcript(text: "explicit cloud fallback")
    )
    let router = TranscriptionProviderRouter(
      appleSpeechEngine: apple,
      appleSpeechCapability: CoordinatorCapability(
        result: .unavailable(.unsupportedLocale)
      ),
      groqEngine: groq,
      groqCapability: CoordinatorCapability(result: .available)
    )
    let coordinator = DictationCoordinator(
      recorder: CoordinatorFakeRecorder(outputURL: audioURL),
      transcriptionRouter: router,
      textProcessor: CoordinatorFakeTextProcessor(),
      historyRepository: try makeHistoryRepository(),
      settingsRepository: FakeSettingsRepository(
        settings: AppSettings(
          transcriptionProviderID: .appleSpeech,
          transcriptionFallbackPolicy: .askBeforeCrossingBoundary,
          dictationHistoryEnabled: false
        )
      ),
      inserter: CoordinatorFakeInserter(result: .inserted),
      manualTextCopier: CoordinatorFakeManualCopier(),
      hud: CoordinatorFakeHUD()
    )

    coordinator.toggle()
    try await waitUntil {
      if case .recording = coordinator.state { return true }
      return false
    }
    coordinator.toggle()
    try await waitUntil { coordinator.fallbackOffer != nil }

    let callsBeforeConsent = await groq.callCount
    XCTAssertEqual(callsBeforeConsent, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

    coordinator.acceptTranscriptionFallback()
    try await waitUntil {
      coordinator.state == .success(text: "explicit cloud fallback")
    }

    let callsAfterConsent = await groq.callCount
    XCTAssertEqual(callsAfterConsent, 1)
    try await waitUntil {
      !FileManager.default.fileExists(atPath: audioURL.path)
    }
  }

  func testDecliningCrossBoundaryFallbackDeletesAudioWithoutCallingProvider()
    async throws
  {
    let audioURL = try makeTemporaryAudio()
    defer { try? FileManager.default.removeItem(at: audioURL) }
    let groq = CoordinatorFakeTranscriber(
      transcript: Transcript(text: "must not run")
    )
    let router = TranscriptionProviderRouter(
      appleSpeechEngine: CoordinatorFakeTranscriber(
        transcript: Transcript(text: "unavailable")
      ),
      appleSpeechCapability: CoordinatorCapability(
        result: .unavailable(.recognizerUnavailable)
      ),
      groqEngine: groq,
      groqCapability: CoordinatorCapability(result: .available)
    )
    let coordinator = DictationCoordinator(
      recorder: CoordinatorFakeRecorder(outputURL: audioURL),
      transcriptionRouter: router,
      textProcessor: CoordinatorFakeTextProcessor(),
      historyRepository: try makeHistoryRepository(),
      settingsRepository: FakeSettingsRepository(
        settings: AppSettings(
          transcriptionProviderID: .appleSpeech,
          transcriptionFallbackPolicy: .askBeforeCrossingBoundary,
          dictationHistoryEnabled: false
        )
      ),
      inserter: CoordinatorFakeInserter(result: .inserted),
      manualTextCopier: CoordinatorFakeManualCopier(),
      hud: CoordinatorFakeHUD()
    )

    coordinator.toggle()
    try await waitUntil {
      if case .recording = coordinator.state { return true }
      return false
    }
    coordinator.toggle()
    try await waitUntil { coordinator.fallbackOffer != nil }
    coordinator.declineTranscriptionFallback()

    guard case .failure = coordinator.state else {
      return XCTFail("Declining the fallback must end the dictation explicitly.")
    }
    let declinedProviderCalls = await groq.callCount
    XCTAssertEqual(declinedProviderCalls, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
  }

  func testLocalOnlyNeverOffersOrCallsCloudFallback() async throws {
    let audioURL = try makeTemporaryAudio()
    defer { try? FileManager.default.removeItem(at: audioURL) }
    let groq = CoordinatorFakeTranscriber(
      transcript: Transcript(text: "must remain local")
    )
    let router = TranscriptionProviderRouter(
      appleSpeechEngine: CoordinatorFakeTranscriber(
        transcript: Transcript(text: "unavailable")
      ),
      appleSpeechCapability: CoordinatorCapability(
        result: .unavailable(.unsupportedLocale)
      ),
      groqEngine: groq,
      groqCapability: CoordinatorCapability(result: .available)
    )
    let coordinator = DictationCoordinator(
      recorder: CoordinatorFakeRecorder(outputURL: audioURL),
      transcriptionRouter: router,
      textProcessor: CoordinatorFakeTextProcessor(),
      historyRepository: try makeHistoryRepository(),
      settingsRepository: FakeSettingsRepository(
        settings: AppSettings(
          transcriptionProviderID: .appleSpeech,
          transcriptionFallbackPolicy: .askBeforeCrossingBoundary,
          localOnly: true,
          dictationHistoryEnabled: false
        )
      ),
      inserter: CoordinatorFakeInserter(result: .inserted),
      manualTextCopier: CoordinatorFakeManualCopier(),
      hud: CoordinatorFakeHUD()
    )

    coordinator.toggle()
    try await waitUntil {
      if case .recording = coordinator.state { return true }
      return false
    }
    coordinator.toggle()
    try await waitUntil {
      if case .failure = coordinator.state { return true }
      return false
    }

    XCTAssertNil(coordinator.fallbackOffer)
    let localOnlyCloudCalls = await groq.callCount
    XCTAssertEqual(localOnlyCloudCalls, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
  }

  private func makeTemporaryAudio() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpeakNote-Coordinator-\(UUID().uuidString)")
      .appendingPathExtension("wav")
    try Data("fixture".utf8).write(to: url, options: .atomic)
    return url
  }

  private func makeHistoryRepository() throws
    -> SwiftDataSessionRepository
  {
    SwiftDataSessionRepository(
      modelContainer: try SpeakNoteModelContainer.inMemory()
    )
  }

  private func waitUntil(
    timeout: TimeInterval = 2,
    _ predicate: @MainActor () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() {
      guard Date() < deadline else {
        XCTFail("Timed out waiting for coordinator state")
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

extension AppSettings {
  fileprivate static var dictationTestValue: AppSettings {
    AppSettings(
      dictationHistoryEnabled: false,
      hasAcknowledgedGroqCloudProcessing: true
    )
  }
}

private struct CoordinatorFakeTextProcessor: TextProcessingEngine {
  func process(
    transcript: Transcript,
    configuration: TextProcessingConfiguration
  ) async throws -> ProcessedText {
    ProcessedText(text: transcript.text)
  }
}

private actor RawFirstAssertingTextProcessor: TextProcessingEngine {
  private let historyRepository: any DictationHistoryStoring
  private let output: String
  private(set) var observedRawBeforeProcessing = false

  init(
    historyRepository: any DictationHistoryStoring,
    output: String
  ) {
    self.historyRepository = historyRepository
    self.output = output
  }

  func process(
    transcript: Transcript,
    configuration: TextProcessingConfiguration
  ) async throws -> ProcessedText {
    observedRawBeforeProcessing =
      try await historyRepository.record(id: transcript.id) != nil
    return ProcessedText(text: output)
  }
}

private struct CoordinatorFailingTextProcessor: TextProcessingEngine {
  func process(
    transcript: Transcript,
    configuration: TextProcessingConfiguration
  ) async throws -> ProcessedText {
    throw URLError(.cannotConnectToHost)
  }
}

private actor CoordinatorFakeRecorder: AudioRecorder {
  let outputURL: URL
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private(set) var cancelCount = 0

  init(outputURL: URL) {
    self.outputURL = outputURL
  }

  func start() async throws {
    startCount += 1
  }

  func stop() async throws -> URL {
    stopCount += 1
    return outputURL
  }

  func cancel() async {
    cancelCount += 1
  }
}

private actor DelayedCancelRecorder: AudioRecorder {
  private(set) var startCount = 0
  private var releaseImmediately = false
  private var cancellationWaiter: CheckedContinuation<Void, Never>?

  func start() async throws {
    startCount += 1
  }

  func stop() async throws -> URL {
    URL(fileURLWithPath: "/tmp/unused.wav")
  }

  func cancel() async {
    guard !releaseImmediately else { return }
    await withCheckedContinuation { continuation in
      if releaseImmediately {
        continuation.resume()
      } else {
        cancellationWaiter = continuation
      }
    }
  }

  func releaseCancellation() {
    releaseImmediately = true
    cancellationWaiter?.resume()
    cancellationWaiter = nil
  }
}

private actor CoordinatorFakeTranscriber: TranscriptionEngine {
  let transcript: Transcript
  private(set) var capturedConfiguration: TranscriptionConfiguration?
  private(set) var callCount = 0

  init(transcript: Transcript) {
    self.transcript = transcript
  }

  func transcribe(
    audioURL: URL,
    configuration: TranscriptionConfiguration
  ) async throws -> Transcript {
    callCount += 1
    capturedConfiguration = configuration
    return transcript
  }
}

private struct CoordinatorCapability: TranscriptionProviderCapabilityChecking {
  let result: ProviderTranscriptionCapability

  func providerCapability(
    for request: TranscriptionCapabilityRequest
  ) async -> ProviderTranscriptionCapability {
    result
  }
}

@MainActor
private final class CoordinatorFakeInserter: TextInserting {
  let result: TextInsertionResult
  private(set) var insertedText: String?
  private(set) var captureCount = 0

  init(result: TextInsertionResult) {
    self.result = result
  }

  func captureTarget() throws -> InsertionTarget {
    captureCount += 1
    return InsertionTarget(
      processIdentifier: 42,
      bundleIdentifier: "com.apple.TextEdit"
    )
  }

  func insert(
    _ text: String,
    into target: InsertionTarget
  ) async throws -> TextInsertionResult {
    insertedText = text
    return result
  }
}

@MainActor
private final class CoordinatorThrowingInserter: TextInserting {
  func captureTarget() throws -> InsertionTarget {
    InsertionTarget(
      processIdentifier: 42,
      bundleIdentifier: "com.apple.TextEdit"
    )
  }

  func insert(
    _ text: String,
    into target: InsertionTarget
  ) async throws -> TextInsertionResult {
    throw TextInsertionError.pasteboardRestoreFailed
  }
}

@MainActor
private final class CoordinatorFakeManualCopier: ManualTextCopying {
  private(set) var copiedText: String?

  func copy(_ text: String) -> Bool {
    copiedText = text
    return true
  }
}

@MainActor
private final class CoordinatorFakeHUD: DictationHUDPresenting {
  private(set) var hideCount = 0

  func showPreparing() {}
  func showRecording(startedAt: Date) {}
  func showTranscribing() {}
  func showProcessing() {}
  func showInserting() {}
  func showSuccess() {}
  func showFailure(_ message: String) {}
  func showCancelled() {}
  func hide() {
    hideCount += 1
  }
}

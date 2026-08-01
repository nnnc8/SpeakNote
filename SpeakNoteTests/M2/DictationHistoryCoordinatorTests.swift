import XCTest

@testable import SpeakNote

@MainActor
final class DictationHistoryCoordinatorTests: XCTestCase {
  func testReprocessAppendsRunWithoutChangingRawTranscript() async throws {
    let repository = try makeRepository()
    let record = try await repository.createRecord(
      NewDictationRecord(
        rawTranscript: "嗯 this is raw",
        detectedLanguage: "en"
      )
    )
    let settings = AppSettings(
      textProcessingModelID: "fixture-model",
      hasAcknowledgedGroqCloudProcessing: true
    )
    let coordinator = DictationHistoryCoordinator(
      historyRepository: repository,
      textProcessor: HistoryFakeTextProcessor(result: .success("This is clean.")),
      settingsRepository: FakeSettingsRepository(settings: settings),
      copier: HistoryFakeCopier()
    )

    await coordinator.load()
    await coordinator.select(record.id)
    await coordinator.reprocess(level: .clean)

    let unchanged = try await repository.record(id: record.id)
    let runs = try await repository.runs(ownerKind: .dictation, ownerID: record.id)
    XCTAssertEqual(unchanged?.rawTranscript, "嗯 this is raw")
    XCTAssertEqual(runs.count, 1)
    XCTAssertEqual(runs.first?.outputText, "This is clean.")
    XCTAssertEqual(runs.first?.status, .succeeded)
    XCTAssertEqual(runs.first?.modelID, "fixture-model")
  }

  func testProviderFailureAppendsFailedRunAndKeepsRaw() async throws {
    let repository = try makeRepository()
    let record = try await repository.createRecord(
      NewDictationRecord(rawTranscript: "raw", detectedLanguage: nil)
    )
    let settings = AppSettings(hasAcknowledgedGroqCloudProcessing: true)
    let coordinator = DictationHistoryCoordinator(
      historyRepository: repository,
      textProcessor: HistoryFakeTextProcessor(result: .failure(.provider)),
      settingsRepository: FakeSettingsRepository(settings: settings),
      copier: HistoryFakeCopier()
    )

    await coordinator.load()
    await coordinator.select(record.id)
    await coordinator.reprocess(level: .polished)

    let runs = try await repository.runs(ownerKind: .dictation, ownerID: record.id)
    XCTAssertEqual(runs.count, 1)
    XCTAssertEqual(runs.first?.status, .failed)
    XCTAssertNil(runs.first?.outputText)
    XCTAssertEqual(runs.first?.errorCategory, "provider")
    XCTAssertEqual(
      coordinator.errorMessage,
      String(
        localized: "Text processing failed. The raw transcript is unchanged."
      )
    )
  }

  func testReprocessRequiresCloudAcknowledgement() async throws {
    let repository = try makeRepository()
    let record = try await repository.createRecord(
      NewDictationRecord(rawTranscript: "raw", detectedLanguage: nil)
    )
    let processor = CountingTextProcessor()
    let coordinator = DictationHistoryCoordinator(
      historyRepository: repository,
      textProcessor: processor,
      settingsRepository: FakeSettingsRepository(),
      copier: HistoryFakeCopier()
    )

    await coordinator.load()
    await coordinator.select(record.id)
    await coordinator.reprocess(level: .clean)
    let callCount = await processor.callCount
    let runs = try await repository.runs(
      ownerKind: .dictation,
      ownerID: record.id
    )

    XCTAssertEqual(callCount, 0)
    XCTAssertTrue(runs.isEmpty)
  }

  private func makeRepository() throws -> SwiftDataSessionRepository {
    SwiftDataSessionRepository(
      modelContainer: try SpeakNoteModelContainer.inMemory()
    )
  }
}

private enum HistoryFixtureError: Error {
  case provider
}

private struct HistoryFakeTextProcessor: TextProcessingEngine {
  let result: Result<String, HistoryFixtureError>

  func process(
    transcript: Transcript,
    configuration: TextProcessingConfiguration
  ) async throws -> ProcessedText {
    ProcessedText(text: try result.get())
  }
}

private actor CountingTextProcessor: TextProcessingEngine {
  private(set) var callCount = 0

  func process(
    transcript: Transcript,
    configuration: TextProcessingConfiguration
  ) async throws -> ProcessedText {
    callCount += 1
    return ProcessedText(text: transcript.text)
  }
}

@MainActor
private final class HistoryFakeCopier: ManualTextCopying {
  func copy(_ text: String) -> Bool { true }
}

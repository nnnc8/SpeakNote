import Foundation
import XCTest

@testable import SpeakNote

final class VocabularyStructuredWorkflowIntegrationTests: XCTestCase {
  func testRulesRunBeforeProviderAndConfigChangesLeaveRawV1Untouched()
    async throws
  {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = id(1)
    let profileID = id(2)
    let ruleID = id(3)
    let fileStore = try SessionFileStore(rootURL: root)
    _ = try await fileStore.prepareSession(
      id: sessionID,
      source: .imported,
      createdAt: Date(timeIntervalSince1970: 1)
    )
    let raw = Transcript(
      id: id(4),
      text: "voice md ships",
      segments: [
        TranscriptSegment(
          id: id(5),
          startTime: 0,
          endTime: 5,
          text: "voice md ships"
        )
      ]
    )
    _ = try await fileStore.writeJSON(
      raw,
      sessionID: sessionID,
      relativePath: "transcripts/raw-v1.json",
      kind: .rawTranscriptJSON,
      createdAt: Date(timeIntervalSince1970: 2)
    )
    let manifestBefore = try await fileStore.manifest(sessionID: sessionID)
    let rawAssetBefore = try XCTUnwrap(
      manifestBefore.assets.first { $0.kind == .rawTranscriptJSON }
    )

    let container = try SpeakNoteModelContainer.inMemory()
    let history = SwiftDataSessionRepository(modelContainer: container)
    _ = try await history.createSession(
      NewRecordingSession(
        id: sessionID,
        title: "Fixture",
        createdAt: Date(timeIntervalSince1970: 1),
        source: .imported,
        status: .completed,
        duration: 5
      )
    )
    let vocabulary = SwiftDataVocabularyRepository(modelContainer: container)
    _ = try await vocabulary.createProfile(Profile(id: profileID, name: "Work"))
    var rule = ReplacementRule(
      id: ruleID,
      profileID: profileID,
      match: "voice md",
      replacement: "VoiceMD"
    )
    _ = try await vocabulary.createReplacementRule(rule)
    let vocabularyService = VocabularyService(repository: vocabulary)
    let settings = M7StructuredSettingsRepository(
      settings: AppSettings(
        activeProfileID: profileID,
        structuredTextModelID: "test-structured-model",
        dictationHistoryEnabled: false,
        hasAcknowledgedGroqCloudProcessing: true
      )
    )
    let engine = M7CapturingStructuredEngine()
    let processor = M5StructuredNoteProcessor(engine: engine)
    let runStore = VoiceNoteStructuredRunStore(
      fileStore: fileStore,
      history: history
    )
    let firstWorkflow = makeWorkflow(
      settings: settings,
      fileStore: fileStore,
      processor: processor,
      runStore: runStore,
      vocabularyService: vocabularyService,
      runID: id(10)
    )

    let first = try await firstWorkflow.process(
      sessionID: sessionID,
      noteType: .generalNotes
    )
    rule.replacement = "SpeakNote"
    _ = try await vocabulary.updateReplacementRule(rule)
    let secondWorkflow = makeWorkflow(
      settings: settings,
      fileStore: fileStore,
      processor: processor,
      runStore: runStore,
      vocabularyService: vocabularyService,
      runID: id(11)
    )
    let second = try await secondWorkflow.process(
      sessionID: sessionID,
      noteType: .generalNotes
    )

    let providerInputs = await engine.capturedTexts()
    XCTAssertEqual(providerInputs, ["VoiceMD ships", "SpeakNote ships"])
    XCTAssertNotEqual(first.run.configurationHash, second.run.configurationHash)

    let manifestAfter = try await fileStore.manifest(sessionID: sessionID)
    let rawAssetAfter = try XCTUnwrap(
      manifestAfter.assets.first { $0.kind == .rawTranscriptJSON }
    )
    let reopenedRaw = try await fileStore.readJSON(
      Transcript.self,
      sessionID: sessionID,
      relativePath: rawAssetAfter.relativePath,
      expectedSHA256: rawAssetAfter.sha256
    )
    let observations = try await vocabulary.correctionObservations(
      profileID: profileID
    )
    XCTAssertEqual(rawAssetAfter, rawAssetBefore)
    XCTAssertEqual(reopenedRaw, raw)
    XCTAssertTrue(observations.isEmpty)
  }

  private func makeWorkflow(
    settings: M7StructuredSettingsRepository,
    fileStore: SessionFileStore,
    processor: M5StructuredNoteProcessor,
    runStore: VoiceNoteStructuredRunStore,
    vocabularyService: VocabularyService,
    runID: UUID
  ) -> VoiceNoteStructuredProcessingWorkflow {
    VoiceNoteStructuredProcessingWorkflow(
      settingsRepository: settings,
      fileStore: fileStore,
      processor: processor,
      runStore: runStore,
      vocabularyProcessor: vocabularyService,
      now: { Date(timeIntervalSince1970: 100) },
      makeID: { runID }
    )
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SpeakNote-M7StructuredWorkflow-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    return url
  }

  private func id(_ suffix: Int) -> UUID {
    UUID(
      uuidString: String(
        format: "00000000-0000-0000-0000-%012d",
        suffix
      )
    )!
  }
}

private actor M7StructuredSettingsRepository: SettingsStoring {
  private var settings: AppSettings

  init(settings: AppSettings) {
    self.settings = settings
  }

  func load() throws -> AppSettings {
    settings
  }

  func save(_ settings: AppSettings) throws {
    self.settings = settings
  }

  func reset() {
    settings = .defaultValue
  }
}

private actor M7CapturingStructuredEngine: M5StructuredNoteEngine {
  private var texts: [String] = []

  func generatePartial(for request: M5StructuredGroupRequest) async throws -> Data {
    texts.append(request.group.text)
    return try response(for: request)
  }

  func repairPartial(
    _ invalidJSON: Data,
    for request: M5StructuredGroupRequest
  ) async throws -> Data {
    try response(for: request)
  }

  func capturedTexts() -> [String] {
    texts
  }

  private func response(for request: M5StructuredGroupRequest) throws -> Data {
    let range = request.group.sourceRange
    let item = StructuredNoteItem(
      text: request.group.text,
      sourceRanges: [range]
    )
    return try JSONEncoder().encode(
      StructuredNotePartial(
        groupIndex: request.group.index,
        noteType: request.noteType,
        title: "Fixture",
        summary: request.group.text,
        sections: [
          StructuredNoteSection(
            title: "Details",
            content: request.group.text,
            sourceRanges: [range]
          )
        ],
        keyPoints: [item],
        sourceRanges: [range]
      )
    )
  }
}

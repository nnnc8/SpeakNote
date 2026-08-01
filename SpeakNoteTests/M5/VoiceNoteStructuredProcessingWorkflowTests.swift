import Foundation
import XCTest

@testable import SpeakNote

final class VoiceNoteStructuredProcessingWorkflowTests: XCTestCase {
  func testSuccessPersistsVerifiedRunWithoutChangingRawTranscript() async throws {
    let fixture = try await makeFixture(runID: uuid(1_001))
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try await fixture.fileStore.manifest(sessionID: fixture.sessionID)
    let rawBefore = try XCTUnwrap(
      before.assets.first { $0.kind == .rawTranscriptJSON }
    )

    let output = try await fixture.workflow.process(
      sessionID: fixture.sessionID,
      noteType: .generalNotes
    )

    XCTAssertEqual(output.run.id, uuid(1_001))
    XCTAssertEqual(output.run.status, .succeeded)
    XCTAssertEqual(output.document?.noteType, .generalNotes)
    XCTAssertTrue(output.markdown?.contains("# Fixture note") == true)
    XCTAssertTrue(output.markdown?.contains("#t=0-10000") == true)
    let after = try await fixture.fileStore.manifest(sessionID: fixture.sessionID)
    XCTAssertEqual(
      after.assets.first { $0.kind == .rawTranscriptJSON },
      rawBefore
    )
    XCTAssertEqual(after.assets.filter { $0.kind == .processingDocument }.count, 1)
    XCTAssertEqual(after.assets.filter { $0.kind == .processingMarkdown }.count, 1)
  }

  func testPartialFailurePersistsFailedGroupsAndSurfacesWarningMetadata()
    async throws
  {
    let transcript = Transcript(
      text: "first second",
      segments: [
        TranscriptSegment(
          id: uuid(1_021),
          startTime: 0,
          endTime: 4,
          text: "first"
        ),
        TranscriptSegment(
          id: uuid(1_022),
          startTime: 700,
          endTime: 704,
          text: "second"
        ),
      ]
    )
    let fixture = try await makeFixture(
      runID: uuid(1_023),
      engine: WorkflowStructuredEngine(mode: .failGroup(1)),
      transcript: transcript,
      sessionDuration: 704
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let output = try await fixture.workflow.process(
      sessionID: fixture.sessionID,
      noteType: .generalNotes
    )

    XCTAssertEqual(output.run.status, .succeeded)
    XCTAssertEqual(
      output.run.errorCategory,
      "partialStructuredResult|1=providerFailure"
    )
    let groupIndex = "1"
    let category = "providerFailure"
    let localizedDetail = String(localized: "group \(groupIndex) (\(category))")
    XCTAssertEqual(
      VoiceNoteStructuredRunWarning.message(for: output.run.errorCategory),
      String(localized: "Partial result: \(localizedDetail) failed.")
    )
    let reopened = try await fixture.workflow.read(
      sessionID: fixture.sessionID,
      runID: output.run.id
    )
    XCTAssertEqual(reopened?.run.errorCategory, output.run.errorCategory)
  }

  func testAggregateTranscriptUsesPersistedSessionDurationInProductionWorkflow()
    async throws
  {
    let fixture = try await makeFixture(
      runID: uuid(1_024),
      transcript: Transcript(text: "aggregate only"),
      sessionDuration: 42
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let output = try await fixture.workflow.process(
      sessionID: fixture.sessionID,
      noteType: .generalNotes
    )

    XCTAssertTrue(output.markdown?.contains("#t=0-42000") == true)
    XCTAssertEqual(
      output.document?.sourceRanges,
      [StructuredSourceRange(startTime: 0, endTime: 42)]
    )
  }

  func testReprocessAppendsSwitchableRunsForSameRawTranscript() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let shared = try await makeSharedFixture(root: root)
    let first = makeWorkflow(
      shared: shared,
      runID: uuid(1_101),
      now: Date(timeIntervalSince1970: 101)
    )
    let second = makeWorkflow(
      shared: shared,
      runID: uuid(1_102),
      now: Date(timeIntervalSince1970: 102)
    )

    _ = try await first.process(
      sessionID: shared.sessionID,
      noteType: .generalNotes
    )
    _ = try await second.process(
      sessionID: shared.sessionID,
      noteType: .classNotes
    )

    let runs = try await second.runs(sessionID: shared.sessionID)
    XCTAssertEqual(runs.map(\.id), [uuid(1_101), uuid(1_102)])
    let firstOutput = try await second.read(
      sessionID: shared.sessionID,
      runID: uuid(1_101)
    )
    let secondOutput = try await second.read(
      sessionID: shared.sessionID,
      runID: uuid(1_102)
    )
    let firstRead = try XCTUnwrap(firstOutput)
    let secondRead = try XCTUnwrap(secondOutput)
    XCTAssertEqual(firstRead.document?.noteType, .generalNotes)
    XCTAssertEqual(secondRead.document?.noteType, .classNotes)
    XCTAssertNotEqual(firstRead.run.configurationHash, secondRead.run.configurationHash)
    let manifest = try await shared.fileStore.manifest(sessionID: shared.sessionID)
    XCTAssertEqual(manifest.assets.filter { $0.kind == .rawTranscriptJSON }.count, 1)
    XCTAssertEqual(manifest.assets.filter { $0.kind == .processingDocument }.count, 2)
  }

  func testAllProviderGroupsFailAppendsFailedRunAndPreservesRaw() async throws {
    let fixture = try await makeFixture(
      runID: uuid(1_201),
      engine: WorkflowStructuredEngine(mode: .fail)
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try await fixture.fileStore.manifest(sessionID: fixture.sessionID)

    do {
      _ = try await fixture.workflow.process(
        sessionID: fixture.sessionID,
        noteType: .meetingMinutes
      )
      XCTFail("An all-group provider failure must fail the processing attempt.")
    } catch let error as StructuredNoteValidationError {
      XCTAssertEqual(error, .noUsablePartials(failedGroups: [0]))
    }

    let runs = try await fixture.workflow.runs(sessionID: fixture.sessionID)
    XCTAssertEqual(runs.map(\.status), [.failed])
    XCTAssertEqual(runs.first?.errorCategory, "structuredValidation")
    let failedOutput = try await fixture.workflow.read(
      sessionID: fixture.sessionID,
      runID: uuid(1_201)
    )
    let failed = try XCTUnwrap(failedOutput)
    XCTAssertNil(failed.document)
    XCTAssertNil(failed.markdown)
    let after = try await fixture.fileStore.manifest(sessionID: fixture.sessionID)
    XCTAssertEqual(after.assets, before.assets)
  }

  func testCancellationAppendsNoRunOrArtifacts() async throws {
    let engine = WorkflowStructuredEngine(mode: .waitForCancellation)
    let fixture = try await makeFixture(runID: uuid(1_301), engine: engine)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let task = Task {
      try await fixture.workflow.process(
        sessionID: fixture.sessionID,
        noteType: .generalNotes
      )
    }
    while await engine.generateCallCount == 0 {
      await Task.yield()
    }

    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Cancellation must escape the workflow.")
    } catch is CancellationError {
      // Expected.
    }

    let runs = try await fixture.workflow.runs(sessionID: fixture.sessionID)
    XCTAssertTrue(runs.isEmpty)
    let manifest = try await fixture.fileStore.manifest(
      sessionID: fixture.sessionID
    )
    XCTAssertFalse(
      manifest.assets.contains {
        $0.kind == .processingDocument || $0.kind == .processingMarkdown
      }
    )
  }

  func testConsentFailureDoesNotCreateAProcessingRun() async throws {
    let fixture = try await makeFixture(
      runID: uuid(1_401),
      settings: AppSettings(hasAcknowledgedGroqCloudProcessing: false)
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    do {
      _ = try await fixture.workflow.process(
        sessionID: fixture.sessionID,
        noteType: .generalNotes
      )
      XCTFail("Cloud disclosure must be acknowledged before processing.")
    } catch let error as VoiceNoteStructuredProcessingError {
      XCTAssertEqual(error, .cloudProcessingConsentRequired)
    }

    let runs = try await fixture.workflow.runs(sessionID: fixture.sessionID)
    XCTAssertTrue(runs.isEmpty)
  }

  private func makeFixture(
    runID: UUID,
    engine: WorkflowStructuredEngine = WorkflowStructuredEngine(mode: .success),
    settings: AppSettings = AppSettings(
      structuredTextModelID: "test-structured-model",
      hasAcknowledgedGroqCloudProcessing: true
    ),
    transcript: Transcript? = nil,
    sessionDuration: TimeInterval = 10
  ) async throws -> WorkflowFixture {
    let root = try temporaryDirectory()
    let shared = try await makeSharedFixture(
      root: root,
      engine: engine,
      settings: settings,
      transcript: transcript,
      sessionDuration: sessionDuration
    )
    return WorkflowFixture(
      root: root,
      sessionID: shared.sessionID,
      fileStore: shared.fileStore,
      workflow: makeWorkflow(
        shared: shared,
        runID: runID,
        now: Date(timeIntervalSince1970: 100)
      )
    )
  }

  private func makeSharedFixture(
    root: URL,
    engine: WorkflowStructuredEngine = WorkflowStructuredEngine(mode: .success),
    settings: AppSettings = AppSettings(
      structuredTextModelID: "test-structured-model",
      hasAcknowledgedGroqCloudProcessing: true
    ),
    transcript: Transcript? = nil,
    sessionDuration: TimeInterval = 10
  ) async throws -> SharedWorkflowFixture {
    let sessionID = uuid(1_000)
    let fileStore = try SessionFileStore(rootURL: root)
    _ = try await fileStore.prepareSession(
      id: sessionID,
      source: .imported,
      createdAt: Date(timeIntervalSince1970: 1)
    )
    let transcript =
      transcript
      ?? Transcript(
        id: uuid(1_010),
        text: "A complete raw transcript.",
        segments: [
          TranscriptSegment(
            id: uuid(1_011),
            startTime: 0,
            endTime: 10,
            text: "A complete raw transcript."
          )
        ]
      )
    _ = try await fileStore.writeJSON(
      transcript,
      sessionID: sessionID,
      relativePath: "transcripts/raw-v1.json",
      kind: .rawTranscriptJSON,
      createdAt: Date(timeIntervalSince1970: 2)
    )
    let container = try SpeakNoteModelContainer.inMemory()
    let repository = SwiftDataSessionRepository(modelContainer: container)
    _ = try await repository.createSession(
      NewRecordingSession(
        id: sessionID,
        title: "Fixture",
        createdAt: Date(timeIntervalSince1970: 1),
        source: .imported,
        status: .completed,
        duration: sessionDuration
      )
    )
    let runStore = VoiceNoteStructuredRunStore(
      fileStore: fileStore,
      history: repository
    )
    return SharedWorkflowFixture(
      sessionID: sessionID,
      fileStore: fileStore,
      settings: FakeSettingsRepository(settings: settings),
      processor: M5StructuredNoteProcessor(engine: engine),
      runStore: runStore
    )
  }

  private func makeWorkflow(
    shared: SharedWorkflowFixture,
    runID: UUID,
    now: Date
  ) -> VoiceNoteStructuredProcessingWorkflow {
    VoiceNoteStructuredProcessingWorkflow(
      settingsRepository: shared.settings,
      fileStore: shared.fileStore,
      processor: shared.processor,
      runStore: shared.runStore,
      now: { now },
      makeID: { runID }
    )
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SpeakNote-VoiceNoteStructuredWorkflow-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    return url
  }

  private func uuid(_ suffix: Int) -> UUID {
    UUID(
      uuidString: String(
        format: "00000000-0000-0000-0000-%012d",
        suffix
      )
    )!
  }
}

private struct WorkflowFixture {
  let root: URL
  let sessionID: UUID
  let fileStore: SessionFileStore
  let workflow: VoiceNoteStructuredProcessingWorkflow
}

private struct SharedWorkflowFixture {
  let sessionID: UUID
  let fileStore: SessionFileStore
  let settings: FakeSettingsRepository
  let processor: M5StructuredNoteProcessor
  let runStore: VoiceNoteStructuredRunStore
}

private actor WorkflowStructuredEngine: M5StructuredNoteEngine {
  enum Mode: Sendable {
    case success
    case fail
    case failGroup(Int)
    case waitForCancellation
  }

  enum FixtureError: Error {
    case providerFailure
  }

  private let mode: Mode
  private(set) var generateCallCount = 0

  init(mode: Mode) {
    self.mode = mode
  }

  func generatePartial(
    for request: M5StructuredGroupRequest
  ) async throws -> Data {
    generateCallCount += 1
    switch mode {
    case .success:
      return try response(for: request)
    case .fail:
      throw FixtureError.providerFailure
    case .failGroup(let index):
      if request.group.index == index {
        throw FixtureError.providerFailure
      }
      return try response(for: request)
    case .waitForCancellation:
      try await Task.sleep(for: .seconds(60))
      return try response(for: request)
    }
  }

  func repairPartial(
    _ invalidJSON: Data,
    for request: M5StructuredGroupRequest
  ) async throws -> Data {
    try response(for: request)
  }

  private func response(for request: M5StructuredGroupRequest) throws -> Data {
    let range = request.group.sourceRange
    let item = StructuredNoteItem(
      text: "Fixture point",
      sourceRanges: [range]
    )
    let partial = StructuredNotePartial(
      groupIndex: request.group.index,
      noteType: request.noteType,
      title: "Fixture note",
      summary: "Fixture summary",
      sections: [
        StructuredNoteSection(
          title: "Details",
          content: "Grounded content",
          sourceRanges: [range]
        )
      ],
      keyPoints: [item],
      sourceRanges: [range],
      lecture: request.noteType == .classNotes
        ? LectureNoteFields(reviewQuestions: [item]) : nil,
      meeting: request.noteType == .meetingMinutes
        ? MeetingNoteFields(decisions: [item]) : nil
    )
    return try JSONEncoder().encode(partial)
  }
}

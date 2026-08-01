import Foundation
import XCTest

@testable import SpeakNote

final class M5StructuredRunStoreTests: XCTestCase {
  func testReopenListsAndReadsSuccessfulAndFailedHistoryInStableOrder() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileRoot = root.appendingPathComponent("AppSupport")
    let databaseURL = root.appendingPathComponent("history.store")
    let sessionID = uuid(600)
    let firstID = uuid(601)
    let secondID = uuid(602)
    let failedID = uuid(603)
    let firstDocument = document(title: "First")
    let secondDocument = document(title: "Second")

    try await writePersistentFixture(
      fileRoot: fileRoot,
      databaseURL: databaseURL,
      sessionID: sessionID,
      firstID: firstID,
      secondID: secondID,
      failedID: failedID,
      firstDocument: firstDocument,
      secondDocument: secondDocument
    )

    let reopenedFileStore = try SessionFileStore(rootURL: fileRoot)
    let reopenedContainer = try SpeakNoteModelContainer.persistent(at: databaseURL)
    let reopenedRepository = SwiftDataSessionRepository(
      modelContainer: reopenedContainer
    )
    let reopened = VoiceNoteStructuredRunStore(
      fileStore: reopenedFileStore,
      history: reopenedRepository
    )

    let runs = try await reopened.runs(sessionID: sessionID)
    XCTAssertEqual(runs.map(\.id), [firstID, secondID, failedID])
    XCTAssertEqual(runs.map(\.status), [.succeeded, .succeeded, .failed])

    let firstValue = try await reopened.read(sessionID: sessionID, runID: firstID)
    let first = try XCTUnwrap(firstValue)
    XCTAssertEqual(first.document, firstDocument)
    XCTAssertEqual(
      first.markdown,
      StructuredNoteMarkdownRenderer().render(firstDocument)
    )

    let secondValue = try await reopened.read(sessionID: sessionID, runID: secondID)
    let second = try XCTUnwrap(secondValue)
    XCTAssertEqual(second.document, secondDocument)

    let failureValue = try await reopened.read(sessionID: sessionID, runID: failedID)
    let failure = try XCTUnwrap(failureValue)
    XCTAssertNil(failure.document)
    XCTAssertNil(failure.markdown)
    XCTAssertEqual(failure.run.errorCategory, "invalid_json")

    let manifest = try await reopenedFileStore.manifest(sessionID: sessionID)
    XCTAssertEqual(manifest.assets.filter { $0.kind == .processingDocument }.count, 2)
    XCTAssertEqual(manifest.assets.filter { $0.kind == .processingMarkdown }.count, 2)
    XCTAssertFalse(
      manifest.assets.contains { $0.relativePath.contains(failedID.uuidString) }
    )
    for asset in manifest.assets {
      let data = try await reopenedFileStore.readData(
        sessionID: sessionID,
        relativePath: asset.relativePath,
        expectedSHA256: asset.sha256
      )
      XCTAssertEqual(Int64(data.count), asset.byteCount)
    }
    let raw = try await reopenedFileStore.readData(
      sessionID: sessionID,
      relativePath: Self.rawPath
    )
    XCTAssertEqual(raw, Self.rawData)
  }

  func testFilesAndManifestCommitBeforeMetadataFailureRollsBackOnlyNewRun()
    async throws
  {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileStore = try SessionFileStore(rootURL: root)
    let sessionID = uuid(700)
    try await prepareFileSession(fileStore, sessionID: sessionID)
    let history = MetadataProbeHistory(rootURL: root)
    let store = VoiceNoteStructuredRunStore(fileStore: fileStore, history: history)
    let prior = newRun(id: uuid(701), sessionID: sessionID, title: "Prior")
    _ = try await store.append(prior)
    let before = try await fileStore.manifest(sessionID: sessionID)

    await history.failNextAppend()
    let rejected = newRun(id: uuid(702), sessionID: sessionID, title: "Rejected")
    do {
      _ = try await store.append(rejected)
      XCTFail("The injected metadata failure must escape")
    } catch {
      XCTAssertEqual(error as? MetadataProbeHistory.ProbeError, .injectedFailure)
    }

    let after = try await fileStore.manifest(sessionID: sessionID)
    let probedRunIDs = await history.probedRunIDs()
    let remainingRunIDs = try await store.runs(sessionID: sessionID).map(\.id)
    let priorRead = try await store.read(sessionID: sessionID, runID: prior.id)
    let raw = try await fileStore.readData(
      sessionID: sessionID,
      relativePath: Self.rawPath
    )
    XCTAssertEqual(after.assets, before.assets)
    XCTAssertEqual(probedRunIDs, [prior.id, rejected.id])
    XCTAssertEqual(remainingRunIDs, [prior.id])
    XCTAssertNotNil(priorRead)
    XCTAssertEqual(raw, Self.rawData)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: runDirectory(root, sessionID: sessionID, runID: rejected.id).path
      )
    )
  }

  func testCancellationCleansPartialRunAndPreservesRawAndPriorHistory() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileStore = try SessionFileStore(rootURL: root)
    let sessionID = uuid(800)
    try await prepareFileSession(fileStore, sessionID: sessionID)
    let history = MetadataProbeHistory(rootURL: root)
    let store = VoiceNoteStructuredRunStore(fileStore: fileStore, history: history)
    let prior = newRun(id: uuid(801), sessionID: sessionID, title: "Prior")
    _ = try await store.append(prior)
    let before = try await fileStore.manifest(sessionID: sessionID)

    let cancelled = newRun(id: uuid(802), sessionID: sessionID, title: "Cancelled")
    let partialURL = runDirectory(
      root,
      sessionID: sessionID,
      runID: cancelled.id
    ).appendingPathExtension("partial")
    try FileManager.default.createDirectory(
      at: partialURL,
      withIntermediateDirectories: true
    )
    try Data("stale".utf8).write(to: partialURL.appendingPathComponent("stale"))

    let gate = CancellationGate()
    let task = Task {
      await gate.wait()
      return try await store.append(cancelled)
    }
    while !(await gate.isWaiting) {
      await Task.yield()
    }
    task.cancel()
    await gate.release()

    do {
      _ = try await task.value
      XCTFail("A cancelled run must not commit")
    } catch is CancellationError {
      // Expected.
    }

    let after = try await fileStore.manifest(sessionID: sessionID)
    let remainingRunIDs = try await store.runs(sessionID: sessionID).map(\.id)
    let raw = try await fileStore.readData(
      sessionID: sessionID,
      relativePath: Self.rawPath
    )
    XCTAssertEqual(after.assets, before.assets)
    XCTAssertEqual(remainingRunIDs, [prior.id])
    XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: runDirectory(
          root,
          sessionID: sessionID,
          runID: cancelled.id
        ).path
      )
    )
    XCTAssertEqual(raw, Self.rawData)
  }

  func testDuplicateRunIDCannotOverwriteArtifactsOrAppendHistory() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileStore = try SessionFileStore(rootURL: root)
    let sessionID = uuid(900)
    try await prepareFileSession(fileStore, sessionID: sessionID)
    let history = MetadataProbeHistory(rootURL: root)
    let store = VoiceNoteStructuredRunStore(fileStore: fileStore, history: history)
    let original = newRun(id: uuid(901), sessionID: sessionID, title: "Original")
    _ = try await store.append(original)
    let before = try await fileStore.manifest(sessionID: sessionID)

    let replacement = newRun(
      id: original.id,
      sessionID: sessionID,
      title: "Replacement"
    )
    do {
      _ = try await store.append(replacement)
      XCTFail("Immutable run files must reject duplicate identifiers")
    } catch {
      XCTAssertEqual(error as? SessionFileStoreError, .assetAlreadyExists)
    }

    let after = try await fileStore.manifest(sessionID: sessionID)
    let runIDs = try await store.runs(sessionID: sessionID).map(\.id)
    let reopenedValue = try await store.read(
      sessionID: sessionID,
      runID: original.id
    )
    let reopened = try XCTUnwrap(reopenedValue)
    XCTAssertEqual(after.assets, before.assets)
    XCTAssertEqual(runIDs, [original.id])
    XCTAssertEqual(reopened.document, original.document)
    XCTAssertEqual(reopened.markdown, original.markdown)
  }

  func testReconcileCompletesCrashAfterManifestBeforeMetadata() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileStore = try SessionFileStore(rootURL: root)
    let sessionID = uuid(1_000)
    try await prepareFileSession(fileStore, sessionID: sessionID)
    let history = MetadataProbeHistory(rootURL: root)
    let pending = newRun(id: uuid(1_001), sessionID: sessionID, title: "Pending")
    let transaction = transaction(for: pending)

    try await fileStore.commitM5StructuredRun(
      transaction: transaction,
      document: pending.document,
      markdown: pending.markdown
    )
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: transactionMarker(
          root,
          sessionID: sessionID,
          runID: pending.id
        ).path
      )
    )

    let relaunched = VoiceNoteStructuredRunStore(
      fileStore: fileStore,
      history: history
    )
    try await relaunched.reconcileM5StructuredRuns()

    let reconciledRunIDs = try await relaunched.runs(sessionID: sessionID).map(\.id)
    let reconciled = try await relaunched.read(
      sessionID: sessionID,
      runID: pending.id
    )
    XCTAssertEqual(reconciledRunIDs, [pending.id])
    XCTAssertEqual(reconciled?.document, pending.document)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: transactionMarker(
          root,
          sessionID: sessionID,
          runID: pending.id
        ).path
      )
    )
  }

  func testReconcileClearsMarkerAfterMetadataWasAlreadyCommitted() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileStore = try SessionFileStore(rootURL: root)
    let sessionID = uuid(1_100)
    try await prepareFileSession(fileStore, sessionID: sessionID)
    let history = MetadataProbeHistory(rootURL: root)
    let pending = newRun(id: uuid(1_101), sessionID: sessionID, title: "Saved")
    let transaction = transaction(for: pending)
    try await fileStore.commitM5StructuredRun(
      transaction: transaction,
      document: pending.document,
      markdown: pending.markdown
    )
    _ = try await history.appendRun(
      NewProcessingRun(
        id: pending.id,
        ownerKind: .voiceNote,
        ownerID: sessionID,
        createdAt: pending.createdAt,
        providerID: pending.metadata.providerID,
        modelID: pending.metadata.modelID,
        configurationHash: pending.metadata.configurationHash,
        outputText: pending.markdown,
        status: .succeeded
      )
    )

    let relaunched = VoiceNoteStructuredRunStore(
      fileStore: fileStore,
      history: history
    )
    try await relaunched.reconcileM5StructuredRuns()

    let reconciledRunIDs = try await relaunched.runs(sessionID: sessionID).map(\.id)
    XCTAssertEqual(reconciledRunIDs, [pending.id])
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: transactionMarker(
          root,
          sessionID: sessionID,
          runID: pending.id
        ).path
      )
    )
  }

  func testReconcileRollsBackCrashAfterFinalFilesBeforeManifest() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileStore = try SessionFileStore(rootURL: root)
    let sessionID = uuid(1_200)
    try await prepareFileSession(fileStore, sessionID: sessionID)
    let history = MetadataProbeHistory(rootURL: root)
    let pending = newRun(id: uuid(1_201), sessionID: sessionID, title: "Orphan")
    try await fileStore.commitM5StructuredRun(
      transaction: transaction(for: pending),
      document: pending.document,
      markdown: pending.markdown
    )
    var manifest = try await fileStore.manifest(sessionID: sessionID)
    manifest.assets.removeAll { $0.relativePath.contains(pending.id.uuidString) }
    let manifestURL = root.appendingPathComponent(
      "Sessions/\(sessionID.uuidString)/manifest.json"
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

    let relaunched = VoiceNoteStructuredRunStore(
      fileStore: fileStore,
      history: history
    )
    try await relaunched.reconcileM5StructuredRuns()

    let reconciledRuns = try await relaunched.runs(sessionID: sessionID)
    XCTAssertTrue(reconciledRuns.isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: runDirectory(
          root,
          sessionID: sessionID,
          runID: pending.id
        ).path
      )
    )
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: transactionMarker(
          root,
          sessionID: sessionID,
          runID: pending.id
        ).path
      )
    )
  }

  func testReconcileRemovesStalePartialDirectoriesWithoutAProviderCall()
    async throws
  {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileStore = try SessionFileStore(rootURL: root)
    let sessionID = uuid(1_300)
    try await prepareFileSession(fileStore, sessionID: sessionID)
    let partialURL = runDirectory(
      root,
      sessionID: sessionID,
      runID: uuid(1_301)
    ).appendingPathExtension("partial")
    try FileManager.default.createDirectory(
      at: partialURL,
      withIntermediateDirectories: true
    )
    try Data("stale".utf8).write(to: partialURL.appendingPathComponent("data"))
    let store = VoiceNoteStructuredRunStore(
      fileStore: fileStore,
      history: MetadataProbeHistory(rootURL: root)
    )

    try await store.reconcileM5StructuredRuns()

    XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))
  }

  func testLaunchRecoveryInvokesM5TransactionReconciliation() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileStore = try SessionFileStore(rootURL: root)
    let sessionID = uuid(1_400)
    _ = try await fileStore.prepareSession(
      id: sessionID,
      source: .imported,
      createdAt: Date(timeIntervalSince1970: 1)
    )
    let container = try SpeakNoteModelContainer.inMemory()
    let repository = SwiftDataSessionRepository(modelContainer: container)
    _ = try await repository.createSession(
      NewRecordingSession(
        id: sessionID,
        title: "Launch fixture",
        createdAt: Date(timeIntervalSince1970: 1),
        source: .imported,
        status: .completed,
        duration: 1
      )
    )
    let probe = M5ReconcileProbe()
    let recovery = VoiceNoteRecoveryManager(
      repository: repository,
      fileStore: fileStore,
      structuredRunReconciler: probe
    )

    _ = try await recovery.reconcile()

    let reconcileCallCount = await probe.callCount
    XCTAssertEqual(reconcileCallCount, 1)
  }

  private func writePersistentFixture(
    fileRoot: URL,
    databaseURL: URL,
    sessionID: UUID,
    firstID: UUID,
    secondID: UUID,
    failedID: UUID,
    firstDocument: ProcessedDocument,
    secondDocument: ProcessedDocument
  ) async throws {
    let fileStore = try SessionFileStore(rootURL: fileRoot)
    try await prepareFileSession(fileStore, sessionID: sessionID)
    let container = try SpeakNoteModelContainer.persistent(at: databaseURL)
    let repository = SwiftDataSessionRepository(modelContainer: container)
    _ = try await repository.createSession(
      NewRecordingSession(
        id: sessionID,
        title: "M5 fixture",
        createdAt: Date(timeIntervalSince1970: 50),
        source: .imported,
        status: .completed,
        duration: 3
      )
    )
    let store = VoiceNoteStructuredRunStore(fileStore: fileStore, history: repository)
    let timestamp = Date(timeIntervalSince1970: 100)
    _ = try await store.append(
      newRun(
        id: secondID,
        sessionID: sessionID,
        title: secondDocument.title,
        createdAt: timestamp
      )
    )
    _ = try await store.appendFailure(
      sessionID: sessionID,
      runID: failedID,
      createdAt: Date(timeIntervalSince1970: 101),
      metadata: metadata,
      errorCategory: "invalid_json"
    )
    _ = try await store.append(
      newRun(
        id: firstID,
        sessionID: sessionID,
        title: firstDocument.title,
        createdAt: timestamp
      )
    )
  }

  private func prepareFileSession(
    _ fileStore: SessionFileStore,
    sessionID: UUID
  ) async throws {
    _ = try await fileStore.prepareSession(
      id: sessionID,
      source: .imported,
      createdAt: Date(timeIntervalSince1970: 50)
    )
    _ = try await fileStore.write(
      Self.rawData,
      sessionID: sessionID,
      relativePath: Self.rawPath,
      kind: .rawTranscriptMarkdown,
      createdAt: Date(timeIntervalSince1970: 51)
    )
  }

  private var metadata: VoiceNoteStructuredRunMetadata {
    VoiceNoteStructuredRunMetadata(
      noteType: .generalNotes,
      providerID: "test-provider",
      modelID: "test-model",
      configurationHash: "general-config-v1"
    )
  }

  private func newRun(
    id: UUID,
    sessionID: UUID,
    title: String,
    createdAt: Date = Date(timeIntervalSince1970: 100)
  ) -> NewVoiceNoteStructuredRun {
    let document = document(title: title)
    return NewVoiceNoteStructuredRun(
      id: id,
      sessionID: sessionID,
      createdAt: createdAt,
      metadata: metadata,
      document: document,
      markdown: StructuredNoteMarkdownRenderer().render(document)
    )
  }

  private func transaction(
    for run: NewVoiceNoteStructuredRun
  ) -> M5StructuredRunTransaction {
    M5StructuredRunTransaction(
      sessionID: run.sessionID,
      runID: run.id,
      createdAt: run.createdAt,
      providerID: run.metadata.providerID,
      modelID: run.metadata.modelID,
      configurationHash: run.metadata.configurationHash,
      errorCategory: VoiceNoteStructuredRunWarning.errorCategory(
        for: run.partialFailures
      )
    )
  }

  private func document(title: String) -> ProcessedDocument {
    ProcessedDocument(
      noteType: .generalNotes,
      title: title,
      summary: "Summary for \(title)",
      sections: [
        StructuredNoteSection(
          title: "Content",
          content: title,
          sourceRanges: [StructuredSourceRange(startTime: 0, endTime: 1)]
        )
      ],
      keyPoints: [],
      actions: [],
      openQuestions: [],
      sourceRanges: [StructuredSourceRange(startTime: 0, endTime: 1)],
      lecture: nil,
      meeting: nil
    )
  }

  private func runDirectory(
    _ root: URL,
    sessionID: UUID,
    runID: UUID
  ) -> URL {
    root.appendingPathComponent(
      "Sessions/\(sessionID.uuidString)/runs/\(runID.uuidString)",
      isDirectory: true
    )
  }

  private func transactionMarker(
    _ root: URL,
    sessionID: UUID,
    runID: UUID
  ) -> URL {
    root.appendingPathComponent(
      "Sessions/\(sessionID.uuidString)/runs/\(runID.uuidString).transaction.json"
    )
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SpeakNote-M5StructuredRunStoreTests-\(UUID().uuidString)",
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

  private static let rawPath = "transcripts/raw-v1.md"
  private static let rawData = Data("raw transcript must remain immutable".utf8)
}

private actor MetadataProbeHistory: VoiceNoteProcessingRunStoring {
  enum ProbeError: Error, Equatable {
    case assetsMissing
    case manifestMissingAssets
    case injectedFailure
  }

  private let rootURL: URL
  private var storedRuns: [ProcessingRunDTO] = []
  private var runIDsSeenWithCommittedFiles: [UUID] = []
  private var shouldFailNextAppend = false

  init(rootURL: URL) {
    self.rootURL = rootURL
  }

  func appendRun(_ run: NewProcessingRun) throws -> ProcessingRunDTO {
    if run.status == .succeeded {
      let directory = rootURL.appendingPathComponent(
        "Sessions/\(run.ownerID.uuidString)/runs/\(run.id.uuidString)",
        isDirectory: true
      )
      let documentPath = "runs/\(run.id.uuidString)/document.json"
      let markdownPath = "runs/\(run.id.uuidString)/note.md"
      guard
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("document.json").path
        ),
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("note.md").path
        )
      else {
        throw ProbeError.assetsMissing
      }
      let manifestURL = rootURL.appendingPathComponent(
        "Sessions/\(run.ownerID.uuidString)/manifest.json"
      )
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .secondsSince1970
      let manifest = try decoder.decode(
        SessionManifest.self,
        from: Data(contentsOf: manifestURL)
      )
      guard
        manifest.assets.contains(where: { $0.relativePath == documentPath }),
        manifest.assets.contains(where: { $0.relativePath == markdownPath })
      else {
        throw ProbeError.manifestMissingAssets
      }
      runIDsSeenWithCommittedFiles.append(run.id)
    }
    if shouldFailNextAppend {
      shouldFailNextAppend = false
      throw ProbeError.injectedFailure
    }
    let dto = ProcessingRunDTO(
      id: run.id,
      ownerKind: run.ownerKind,
      ownerID: run.ownerID,
      createdAt: run.createdAt,
      providerID: run.providerID,
      modelID: run.modelID,
      configurationHash: run.configurationHash,
      outputText: run.outputText,
      status: run.status,
      errorCategory: run.errorCategory
    )
    storedRuns.append(dto)
    return dto
  }

  func runs(
    ownerKind: ProcessingRunOwnerKind,
    ownerID: UUID
  ) throws -> [ProcessingRunDTO] {
    storedRuns
      .filter { $0.ownerKind == ownerKind && $0.ownerID == ownerID }
      .sorted {
        if $0.createdAt != $1.createdAt {
          return $0.createdAt < $1.createdAt
        }
        return $0.id.uuidString < $1.id.uuidString
      }
  }

  func failNextAppend() {
    shouldFailNextAppend = true
  }

  func probedRunIDs() -> [UUID] {
    runIDsSeenWithCommittedFiles
  }
}

private actor CancellationGate {
  private var continuation: CheckedContinuation<Void, Never>?

  var isWaiting: Bool {
    continuation != nil
  }

  func wait() async {
    await withCheckedContinuation { continuation = $0 }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private actor M5ReconcileProbe: M5StructuredRunReconciling {
  private(set) var callCount = 0

  func reconcileM5StructuredRuns() {
    callCount += 1
  }
}

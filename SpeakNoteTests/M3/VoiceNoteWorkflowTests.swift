import Foundation
import XCTest

@testable import SpeakNote

final class VoiceNoteWorkflowTests: XCTestCase {
  func testImportRequiresGroqConsentBeforeCreatingSession() async throws {
    let context = try makeContext(
      settings: AppSettings(hasAcknowledgedGroqCloudProcessing: false)
    )
    defer { context.removeFiles() }

    do {
      _ = try await context.workflow.importAndStart(
        url: context.sourceURL,
        title: nil
      )
      XCTFail("Expected cloud processing consent to be required.")
    } catch {
      XCTAssertEqual(
        error as? VoiceNoteWorkflowError,
        .cloudProcessingConsentRequired
      )
    }

    let importRequestCount = await context.importer.requestCount
    let sessions = await context.repository.allSessions
    XCTAssertEqual(importRequestCount, 0)
    XCTAssertTrue(sessions.isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: context.rootURL.appendingPathComponent("Sessions").path
      )
    )
  }

  func testAppleSpeechImportDoesNotRequireGroqConsent() async throws {
    var settings = AppSettings(
      transcriptionProviderID: .appleSpeech,
      localOnly: true,
      hasAcknowledgedGroqCloudProcessing: false
    )
    settings.transcriptionModelID = "apple-on-device"
    let context = try makeContext(settings: settings)
    defer { context.removeFiles() }

    let sessionID = try await context.workflow.importAndStart(
      url: context.sourceURL,
      title: nil
    )
    let didStart = await eventually {
      await context.pipeline.processRequests.count == 1
    }

    XCTAssertTrue(didStart)
    let requests = await context.pipeline.processRequests
    XCTAssertEqual(requests.first?.sessionID, sessionID)
    XCTAssertEqual(requests.first?.configuration.providerID, .appleSpeech)
    XCTAssertEqual(requests.first?.configuration.modelID, "apple-on-device")

    await context.workflow.cancel(sessionID: sessionID)
  }

  func testExplicitAlternativeRetryCreatesNewJobWithoutMixingProviders()
    async throws
  {
    let context = try makeContext(
      appleSpeechCapability: FakeWorkflowCapability(result: .available)
    )
    defer { context.removeFiles() }
    let sessionID = try await context.workflow.importAndStart(
      url: context.sourceURL,
      title: nil
    )
    let firstJobStarted = await eventually {
      await context.pipeline.processRequests.count == 1
    }
    XCTAssertTrue(firstJobStarted)
    await context.workflow.cancel(sessionID: sessionID)

    let alternative = try await context.workflow.availableAlternativeProvider(
      sessionID: sessionID
    )
    XCTAssertEqual(alternative, .appleSpeech)

    try await context.workflow.retry(
      sessionID: sessionID,
      using: .appleSpeech
    )
    let alternativeJobStarted = await eventually {
      await context.pipeline.processRequests.count == 2
    }
    XCTAssertTrue(alternativeJobStarted)
    let requests = await context.pipeline.processRequests
    XCTAssertNotEqual(requests[0].jobID, requests[1].jobID)
    XCTAssertEqual(requests[0].configuration.providerID, .groq)
    XCTAssertEqual(requests[1].configuration.providerID, .appleSpeech)

    await context.workflow.cancel(sessionID: sessionID)
  }

  func testSuccessfulImportPersistsSessionAndJobAndStartsConfiguredPipeline()
    async throws
  {
    var settings = AppSettings(hasAcknowledgedGroqCloudProcessing: true)
    settings.transcriptionModelID = "workflow-test-model"
    settings.recognitionLanguageCode = "zh-TW"
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let context = try makeContext(settings: settings, now: now)
    defer { context.removeFiles() }

    let sessionID = try await context.workflow.importAndStart(
      url: context.sourceURL,
      title: "  Planning  "
    )

    let didStart = await eventually {
      await context.pipeline.processRequests.count == 1
    }
    XCTAssertTrue(didStart)

    let storedSession = try await context.repository.session(id: sessionID)
    let session = try XCTUnwrap(storedSession)
    let jobID = try XCTUnwrap(session.currentJobID)
    let storedJob = try await context.repository.job(id: jobID)
    let job = try XCTUnwrap(storedJob)
    XCTAssertEqual(session.title, "Planning")
    XCTAssertEqual(session.createdAt, now)
    XCTAssertEqual(session.source, .imported)
    XCTAssertEqual(session.status, .preprocessing)
    XCTAssertEqual(session.duration, 42.5)
    XCTAssertEqual(job.sessionID, sessionID)
    XCTAssertEqual(job.stage, .queued)

    let processRequests = await context.pipeline.processRequests
    let request = try XCTUnwrap(processRequests.first)
    XCTAssertEqual(request.sessionID, sessionID)
    XCTAssertEqual(request.jobID, jobID)
    XCTAssertEqual(request.sourceRelativePath, "audio/imported-original.m4a")
    XCTAssertEqual(request.sourceDuration, 42.5)
    XCTAssertEqual(
      request.configuration,
      TranscriptionConfiguration(
        providerID: .groq,
        modelID: "workflow-test-model",
        languageCode: "zh-TW"
      )
    )

    let files = try regularFilePaths(relativeTo: context.rootURL)
    XCTAssertEqual(
      Set(files),
      [
        "Sessions/\(sessionID.uuidString)/audio/imported-original.m4a",
        "Sessions/\(sessionID.uuidString)/manifest.json",
      ]
    )
    XCTAssertFalse(
      files.contains {
        let name = $0.lowercased()
        return name.contains("transcript")
          || name.contains("key")
          || name.contains("log")
      }
    )

    await context.workflow.cancel(sessionID: sessionID)
  }

  func testCancelWaitsForPipelineCheckpointAndStatePersistence() async throws {
    let context = try makeContext()
    defer { context.removeFiles() }
    let sessionID = try await context.workflow.importAndStart(
      url: context.sourceURL,
      title: nil
    )
    let didStart = await eventually {
      await context.pipeline.processRequests.count == 1
    }
    XCTAssertTrue(didStart)

    await context.workflow.cancel(sessionID: sessionID)

    let completedCancellationCount =
      await context.pipeline.completedCancellationCount
    XCTAssertEqual(completedCancellationCount, 1)
    let manifest = try await context.fileStore.manifest(sessionID: sessionID)
    XCTAssertEqual(manifest.state, .ready)
    XCTAssertTrue(
      manifest.assets.contains {
        $0.kind == .checkpoint
          && $0.relativePath.hasSuffix("/checkpoint.json")
      }
    )
  }

  func testResumeDoesNotStartDuplicateActiveJob() async throws {
    let sessionID = UUID()
    let jobID = UUID()
    let context = try makeContext(
      sessions: [makeSession(id: sessionID, currentJobID: jobID)],
      jobs: [makeJob(id: jobID, sessionID: sessionID)]
    )
    defer { context.removeFiles() }
    _ = try await context.fileStore.prepareSession(
      id: sessionID,
      source: .imported
    )
    try await context.fileStore.writeRecordingJournal(
      RecordingJournal(
        sessionID: sessionID,
        startedAt: Date(timeIntervalSince1970: 1),
        segmentDuration: 300,
        state: .interrupted
      )
    )

    try await context.workflow.resume(sessionID: sessionID)
    let didStart = await eventually {
      await context.pipeline.resumeRequests == [sessionID]
    }
    XCTAssertTrue(didStart)

    do {
      try await context.workflow.resume(sessionID: sessionID)
      XCTFail("Expected the active job to reject a duplicate resume.")
    } catch {
      XCTAssertEqual(
        error as? VoiceNoteWorkflowError,
        .operationAlreadyRunning
      )
    }
    let resumeRequests = await context.pipeline.resumeRequests
    XCTAssertEqual(resumeRequests, [sessionID])

    await context.workflow.cancel(sessionID: sessionID)
  }

  func testDeleteMarksPendingRemovesFilesThenDeletesMetadata() async throws {
    let sessionID = UUID()
    let context = try makeContext(
      sessions: [makeSession(id: sessionID)]
    )
    defer { context.removeFiles() }
    _ = try await context.fileStore.prepareSession(
      id: sessionID,
      source: .imported
    )
    let sessionDirectory = context.rootURL
      .appendingPathComponent("Sessions", isDirectory: true)
      .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    await context.repository.observeDeletionDirectory(sessionDirectory)

    try await context.workflow.delete(sessionID: sessionID)

    let events = await context.repository.events
    let directoryExistedAtMetadataDeletion =
      await context.repository.directoryExistedAtMetadataDeletion
    let deletedSession = try await context.repository.session(id: sessionID)
    let journal = try await context.fileStore.recordingJournal()
    XCTAssertEqual(
      events,
      [
        .updateSession(sessionID, .pendingDeletion),
        .deleteMetadata(sessionID),
      ]
    )
    XCTAssertFalse(directoryExistedAtMetadataDeletion)
    XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))
    XCTAssertNil(journal)
    XCTAssertNil(deletedSession)
  }

  func testImportFailureRollsBackPreparedFilesAndMetadata() async throws {
    let context = try makeContext(importFailure: .importFailed)
    defer { context.removeFiles() }

    do {
      _ = try await context.workflow.importAndStart(
        url: context.sourceURL,
        title: "Failed import"
      )
      XCTFail("Expected the importer failure.")
    } catch {
      XCTAssertEqual(error as? WorkflowTestError, .importFailed)
    }

    let requestedSessionIDs = await context.importer.requestedSessionIDs
    let sessionID = try XCTUnwrap(requestedSessionIDs.first)
    let sawPreparedManifest = await context.importer.sawPreparedManifest
    let events = await context.repository.events
    let sessions = await context.repository.allSessions
    let processRequests = await context.pipeline.processRequests
    XCTAssertTrue(sawPreparedManifest)
    XCTAssertEqual(
      events,
      [.deleteMetadata(sessionID)]
    )
    XCTAssertTrue(sessions.isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: context.rootURL
          .appendingPathComponent("Sessions", isDirectory: true)
          .appendingPathComponent(sessionID.uuidString, isDirectory: true)
          .path
      )
    )
    XCTAssertTrue(processRequests.isEmpty)
  }

  private func makeContext(
    settings: AppSettings = AppSettings(
      hasAcknowledgedGroqCloudProcessing: true
    ),
    sessions: [RecordingSessionDTO] = [],
    jobs: [TranscriptionJobDTO] = [],
    importFailure: WorkflowTestError? = nil,
    appleSpeechCapability:
      (any TranscriptionProviderCapabilityChecking)? = nil,
    now: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) throws -> WorkflowTestContext {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("VoiceNoteWorkflowTests-\(UUID().uuidString)")
    let fileStore = try SessionFileStore(rootURL: rootURL)
    let repository = FakeWorkflowRepository(
      sessions: sessions,
      jobs: jobs
    )
    let settingsRepository = FakeWorkflowSettingsRepository(settings: settings)
    let importer = FakeWorkflowAudioImporter(
      fileStore: fileStore,
      failure: importFailure
    )
    let pipeline = FakeWorkflowPipeline(fileStore: fileStore)
    let workflow = VoiceNoteWorkflow(
      repository: repository,
      settingsRepository: settingsRepository,
      fileStore: fileStore,
      audioImporter: importer,
      pipeline: pipeline,
      appleSpeechCapability: appleSpeechCapability,
      now: { now }
    )
    return WorkflowTestContext(
      rootURL: rootURL,
      sourceURL: URL(fileURLWithPath: "/tmp/workflow-source.m4a"),
      fileStore: fileStore,
      repository: repository,
      importer: importer,
      pipeline: pipeline,
      workflow: workflow
    )
  }
}

private struct WorkflowTestContext {
  let rootURL: URL
  let sourceURL: URL
  let fileStore: SessionFileStore
  let repository: FakeWorkflowRepository
  let importer: FakeWorkflowAudioImporter
  let pipeline: FakeWorkflowPipeline
  let workflow: VoiceNoteWorkflow

  func removeFiles() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

private enum WorkflowTestError: Error, Equatable, Sendable {
  case importFailed
  case unexpectedCall
}

private struct FakeWorkflowCapability: TranscriptionProviderCapabilityChecking {
  let result: ProviderTranscriptionCapability

  func providerCapability(
    for request: TranscriptionCapabilityRequest
  ) async -> ProviderTranscriptionCapability {
    result
  }
}

private actor FakeWorkflowSettingsRepository: SettingsStoring {
  private var settings: AppSettings

  init(settings: AppSettings) {
    self.settings = settings
  }

  func load() throws -> AppSettings {
    settings
  }

  func save(_ settings: AppSettings) {
    self.settings = settings
  }

  func reset() {
    settings = .defaultValue
  }
}

private actor FakeWorkflowAudioImporter: AudioImporting {
  private let fileStore: SessionFileStore
  private let failure: WorkflowTestError?
  private(set) var requestedSessionIDs: [UUID] = []
  private(set) var sawPreparedManifest = false

  init(
    fileStore: SessionFileStore,
    failure: WorkflowTestError?
  ) {
    self.fileStore = fileStore
    self.failure = failure
  }

  var requestCount: Int {
    requestedSessionIDs.count
  }

  func importAudio(from url: URL, sessionID: UUID) async throws -> ImportedAudio {
    _ = url
    requestedSessionIDs.append(sessionID)
    _ = try await fileStore.manifest(sessionID: sessionID)
    sawPreparedManifest = true
    if let failure {
      throw failure
    }
    let asset = try await fileStore.write(
      Data("test-m4a".utf8),
      sessionID: sessionID,
      relativePath: "audio/imported-original.m4a",
      kind: .importedOriginal
    )
    return ImportedAudio(asset: asset, duration: 42.5)
  }
}

private actor FakeWorkflowPipeline: VoiceNoteTranscriptionPipelining {
  struct ProcessRequest: Equatable, Sendable {
    let sessionID: UUID
    let jobID: UUID
    let sourceRelativePath: String
    let sourceDuration: TimeInterval
    let configuration: TranscriptionConfiguration
  }

  private let fileStore: SessionFileStore
  private(set) var processRequests: [ProcessRequest] = []
  private(set) var resumeRequests: [UUID] = []
  private(set) var completedCancellationCount = 0

  init(fileStore: SessionFileStore) {
    self.fileStore = fileStore
  }

  func process(
    sessionID: UUID,
    jobID: UUID,
    sourceRelativePath: String,
    sourceDuration: TimeInterval,
    configuration: TranscriptionConfiguration
  ) async throws {
    processRequests.append(
      ProcessRequest(
        sessionID: sessionID,
        jobID: jobID,
        sourceRelativePath: sourceRelativePath,
        sourceDuration: sourceDuration,
        configuration: configuration
      )
    )
    try await waitForCancellation(sessionID: sessionID, jobID: jobID)
  }

  func resume(
    sessionID: UUID,
    configuration: TranscriptionConfiguration
  ) async throws {
    _ = configuration
    resumeRequests.append(sessionID)
    try await waitForCancellation(sessionID: sessionID, jobID: nil)
  }

  private func waitForCancellation(
    sessionID: UUID,
    jobID: UUID?
  ) async throws {
    do {
      try await Task.sleep(for: .seconds(60))
      throw WorkflowTestError.unexpectedCall
    } catch is CancellationError {
      if let jobID {
        _ = try await fileStore.write(
          Data("checkpoint".utf8),
          sessionID: sessionID,
          relativePath: "jobs/\(jobID.uuidString)/checkpoint.json",
          kind: .checkpoint
        )
      }
      try await fileStore.updateState(
        sessionID: sessionID,
        state: .ready
      )
      completedCancellationCount += 1
      throw CancellationError()
    }
  }
}

private actor FakeWorkflowRepository: VoiceNoteSessionStoring {
  enum Event: Equatable, Sendable {
    case updateSession(UUID, VoiceNoteSessionStatus)
    case deleteMetadata(UUID)
  }

  private var storedSessions: [RecordingSessionDTO]
  private var storedJobs: [TranscriptionJobDTO]
  private var deletionDirectory: URL?
  private(set) var events: [Event] = []
  private(set) var directoryExistedAtMetadataDeletion = false

  init(
    sessions: [RecordingSessionDTO],
    jobs: [TranscriptionJobDTO]
  ) {
    storedSessions = sessions
    storedJobs = jobs
  }

  var allSessions: [RecordingSessionDTO] {
    storedSessions
  }

  func observeDeletionDirectory(_ url: URL) {
    deletionDirectory = url
  }

  func createSession(
    _ session: NewRecordingSession
  ) throws -> RecordingSessionDTO {
    let dto = RecordingSessionDTO(
      id: session.id,
      title: session.title,
      createdAt: session.createdAt,
      updatedAt: session.createdAt,
      source: session.source,
      status: session.status,
      duration: session.duration,
      currentJobID: nil,
      needsRepair: false
    )
    storedSessions.append(dto)
    return dto
  }

  func session(id: UUID) throws -> RecordingSessionDTO? {
    storedSessions.first { $0.id == id }
  }

  func sessions() throws -> [RecordingSessionDTO] {
    storedSessions
  }

  func updateSession(
    id: UUID,
    status: VoiceNoteSessionStatus,
    duration: TimeInterval,
    currentJobID: UUID?,
    updatedAt: Date
  ) throws -> RecordingSessionDTO {
    guard let current = storedSessions.first(where: { $0.id == id }) else {
      throw SessionRepositoryError.sessionNotFound(id)
    }
    let updated = RecordingSessionDTO(
      id: current.id,
      title: current.title,
      createdAt: current.createdAt,
      updatedAt: updatedAt,
      source: current.source,
      status: status,
      duration: duration,
      currentJobID: currentJobID,
      needsRepair: current.needsRepair
    )
    storedSessions.removeAll { $0.id == id }
    storedSessions.append(updated)
    events.append(.updateSession(id, status))
    return updated
  }

  func renameSession(
    id: UUID,
    title: String,
    updatedAt: Date
  ) throws -> RecordingSessionDTO {
    _ = id
    _ = title
    _ = updatedAt
    throw WorkflowTestError.unexpectedCall
  }

  func markSessionNeedsRepair(
    id: UUID,
    updatedAt: Date
  ) throws -> RecordingSessionDTO {
    _ = id
    _ = updatedAt
    throw WorkflowTestError.unexpectedCall
  }

  func createJob(_ job: NewTranscriptionJob) throws -> TranscriptionJobDTO {
    guard storedSessions.contains(where: { $0.id == job.sessionID }) else {
      throw SessionRepositoryError.sessionNotFound(job.sessionID)
    }
    let dto = TranscriptionJobDTO(
      id: job.id,
      sessionID: job.sessionID,
      createdAt: job.createdAt,
      updatedAt: job.createdAt,
      stage: job.stage,
      completedChunks: job.completedChunks,
      totalChunks: job.totalChunks,
      checkpointRelativePath: job.checkpointRelativePath,
      errorCategory: nil
    )
    storedJobs.append(dto)
    return dto
  }

  func job(id: UUID) throws -> TranscriptionJobDTO? {
    storedJobs.first { $0.id == id }
  }

  func jobs(sessionID: UUID) throws -> [TranscriptionJobDTO] {
    storedJobs.filter { $0.sessionID == sessionID }
  }

  func updateJob(
    id: UUID,
    stage: TranscriptionJobStage,
    completedChunks: Int,
    totalChunks: Int,
    checkpointRelativePath: String?,
    errorCategory: String?,
    updatedAt: Date
  ) throws -> TranscriptionJobDTO {
    _ = id
    _ = stage
    _ = completedChunks
    _ = totalChunks
    _ = checkpointRelativePath
    _ = errorCategory
    _ = updatedAt
    throw WorkflowTestError.unexpectedCall
  }

  func deleteSessionMetadata(id: UUID) throws {
    if let deletionDirectory {
      directoryExistedAtMetadataDeletion = FileManager.default.fileExists(
        atPath: deletionDirectory.path
      )
    }
    storedSessions.removeAll { $0.id == id }
    storedJobs.removeAll { $0.sessionID == id }
    events.append(.deleteMetadata(id))
  }
}

private func makeSession(
  id: UUID,
  currentJobID: UUID? = nil
) -> RecordingSessionDTO {
  RecordingSessionDTO(
    id: id,
    title: "Existing voice note",
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 2),
    source: .imported,
    status: .retryRequired,
    duration: 42.5,
    currentJobID: currentJobID,
    needsRepair: false
  )
}

private func makeJob(id: UUID, sessionID: UUID) -> TranscriptionJobDTO {
  TranscriptionJobDTO(
    id: id,
    sessionID: sessionID,
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 2),
    stage: .retryRequired,
    completedChunks: 1,
    totalChunks: 2,
    checkpointRelativePath: "jobs/\(id.uuidString)/checkpoint.json",
    errorCategory: "transcriptionProvider"
  )
}

private func eventually(
  _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
  for _ in 0..<1_000 {
    if await predicate() {
      return true
    }
    await Task.yield()
  }
  return false
}

private func regularFilePaths(relativeTo rootURL: URL) throws -> [String] {
  let resolvedRoot = rootURL.resolvingSymlinksInPath()
  guard
    let enumerator = FileManager.default.enumerator(
      at: resolvedRoot,
      includingPropertiesForKeys: [.isRegularFileKey]
    )
  else {
    return []
  }
  return try enumerator.compactMap { element -> String? in
    guard let url = element as? URL,
      try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
    else {
      return nil
    }
    return url.resolvingSymlinksInPath().pathComponents
      .dropFirst(resolvedRoot.pathComponents.count)
      .joined(separator: "/")
  }
  .sorted()
}

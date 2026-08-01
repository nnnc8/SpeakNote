import Foundation
import XCTest

@testable import SpeakNote

@MainActor
final class VoiceNoteCoordinatorTests: XCTestCase {
  func testLoadAndSelectExposeDurableSessionAndJobState() async {
    let sessionID = UUID()
    let jobID = UUID()
    let session = makeSession(
      id: sessionID,
      status: .transcribing,
      currentJobID: jobID
    )
    let job = makeJob(
      id: jobID,
      sessionID: sessionID,
      completedChunks: 2,
      totalChunks: 5
    )
    let repository = FakeVoiceNoteRepository(
      sessions: [session],
      jobs: [job]
    )
    let coordinator = makeCoordinator(
      repository: repository,
      settings: AppSettings(defaultVoiceNoteType: .meetingMinutes)
    )

    await coordinator.load()
    await coordinator.select(sessionID)

    XCTAssertEqual(coordinator.sessions, [session])
    XCTAssertEqual(coordinator.selectedSession, session)
    XCTAssertEqual(coordinator.jobs, [job])
    XCTAssertEqual(coordinator.selectedJob, job)
    XCTAssertEqual(coordinator.selectedNoteType, .meetingMinutes)
  }

  func testImportUsesPickerStartsWorkflowAndRefreshesSelection() async {
    let importedID = UUID()
    let fileURL = URL(fileURLWithPath: "/tmp/meeting.m4a")
    let repository = FakeVoiceNoteRepository()
    let workflow = FakeVoiceNoteWorkflow(
      repository: repository,
      importedSessionID: importedID
    )
    let coordinator = VoiceNoteCoordinator(
      sessionRepository: repository,
      settingsRepository: VoiceNoteCoordinatorSettingsRepository(),
      workflow: workflow,
      filePicker: FakeVoiceNoteFilePicker(url: fileURL)
    )

    await coordinator.importVoiceNote(title: "Planning")

    let requests = await workflow.importRequests
    XCTAssertEqual(requests.map(\.url), [fileURL])
    XCTAssertEqual(requests.map(\.title), ["Planning"])
    XCTAssertEqual(coordinator.selectedSessionID, importedID)
    XCTAssertEqual(coordinator.sessions.map(\.id), [importedID])
  }

  func testRetryRepairAndCancelUseWorkflowThenRefreshState() async {
    let session = makeSession(status: .retryRequired)
    let repository = FakeVoiceNoteRepository(sessions: [session])
    let workflow = FakeVoiceNoteWorkflow(repository: repository)
    let coordinator = makeCoordinator(
      repository: repository,
      workflow: workflow
    )
    await coordinator.load()
    await coordinator.select(session.id)

    await coordinator.retrySelected()
    await coordinator.repairSelected()
    await coordinator.cancelSelected()

    let resumeIDs = await workflow.resumeIDs
    let cancelIDs = await workflow.cancelIDs
    let sessionsCallCount = await repository.sessionsCallCount
    XCTAssertEqual(resumeIDs, [session.id, session.id])
    XCTAssertEqual(cancelIDs, [session.id])
    XCTAssertEqual(sessionsCallCount, 4)
  }

  func testRenameAndDeleteUpdateDurableState() async {
    let session = makeSession(title: "Old name")
    let repository = FakeVoiceNoteRepository(sessions: [session])
    let workflow = FakeVoiceNoteWorkflow(repository: repository)
    let coordinator = makeCoordinator(
      repository: repository,
      workflow: workflow
    )
    await coordinator.load()
    await coordinator.select(session.id)

    coordinator.renameDraft = "  New name  "
    await coordinator.renameSelected()

    XCTAssertEqual(coordinator.selectedSession?.title, "New name")
    XCTAssertEqual(coordinator.renameDraft, "New name")

    await coordinator.deleteSelected()

    let deleteIDs = await workflow.deleteIDs
    XCTAssertEqual(deleteIDs, [session.id])
    XCTAssertTrue(coordinator.sessions.isEmpty)
    XCTAssertNil(coordinator.selectedSessionID)
  }

  func testWorkflowErrorIsVisibleAndLastStateIsRefreshed() async {
    let session = makeSession(status: .retryRequired)
    let repository = FakeVoiceNoteRepository(sessions: [session])
    let workflow = FakeVoiceNoteWorkflow(repository: repository)
    await workflow.setFailure(.resume)
    let coordinator = makeCoordinator(
      repository: repository,
      workflow: workflow
    )
    await coordinator.load()
    await coordinator.select(session.id)

    await coordinator.retrySelected()

    XCTAssertEqual(
      coordinator.errorMessage,
      String(localized: "The transcription could not be retried.")
    )
    XCTAssertEqual(coordinator.selectedSession, session)
    XCTAssertFalse(coordinator.isBusy)
    let sessionsCallCount = await repository.sessionsCallCount
    XCTAssertEqual(sessionsCallCount, 2)
  }

  func testMonitorRefreshesSelectedSessionUntilItReachesTerminalState() async throws {
    let sessionID = UUID()
    let jobID = UUID()
    let repository = FakeVoiceNoteRepository(
      sessions: [
        makeSession(
          id: sessionID,
          status: .transcribing,
          currentJobID: jobID
        )
      ],
      jobs: [
        makeJob(
          id: jobID,
          sessionID: sessionID,
          completedChunks: 1,
          totalChunks: 2
        )
      ]
    )
    let coordinator = makeCoordinator(repository: repository)
    await coordinator.load()
    await coordinator.select(sessionID)

    _ = try await repository.updateJob(
      id: jobID,
      stage: .completed,
      completedChunks: 2,
      totalChunks: 2,
      checkpointRelativePath: "checkpoints/job.json",
      errorCategory: nil,
      updatedAt: Date(timeIntervalSince1970: 3)
    )
    _ = try await repository.updateSession(
      id: sessionID,
      status: .completed,
      duration: 90,
      currentJobID: jobID,
      updatedAt: Date(timeIntervalSince1970: 3)
    )

    await coordinator.monitorSelectedSession()

    XCTAssertEqual(coordinator.selectedSession?.status, .completed)
    XCTAssertEqual(coordinator.selectedJob?.stage, .completed)
    XCTAssertEqual(coordinator.selectedJob?.completedChunks, 2)
  }

  func testRecordingRecoveryActionsAreRoutedThroughInjectedActors() async {
    let repository = FakeVoiceNoteRepository()
    let recording = FakeCoordinatorRecordingWorkflow(repository: repository)
    let recovery = FakeCoordinatorRecoveryManager()
    let coordinator = VoiceNoteCoordinator(
      sessionRepository: repository,
      settingsRepository: VoiceNoteCoordinatorSettingsRepository(),
      workflow: FakeVoiceNoteWorkflow(repository: repository),
      filePicker: FakeVoiceNoteFilePicker(),
      recordingWorkflow: recording,
      recoveryManager: recovery
    )

    await coordinator.load()
    await coordinator.startRecording(title: "Lecture")
    let sessionID = coordinator.selectedSessionID
    await coordinator.pauseRecording()
    await coordinator.resumeRecording()
    await coordinator.cancelActiveRecording()
    await coordinator.keepSelectedRecording()
    await coordinator.recoverSelectedRecording()
    let reconcileCount = await recovery.reconcileCount
    let pauseCount = await recording.pauseCount
    let resumeCount = await recording.resumeCount
    let cancelCount = await recording.cancelCount
    let keepIDs = await recording.keepIDs
    let recoverIDs = await recording.recoverIDs

    XCTAssertNotNil(sessionID)
    XCTAssertEqual(coordinator.selectedSession?.title, "Lecture")
    XCTAssertEqual(coordinator.selectedSession?.status, .preprocessing)
    XCTAssertEqual(reconcileCount, 1)
    XCTAssertEqual(pauseCount, 1)
    XCTAssertEqual(resumeCount, 1)
    XCTAssertEqual(cancelCount, 1)
    XCTAssertEqual(keepIDs, sessionID.map { [$0] } ?? [])
    XCTAssertEqual(recoverIDs, sessionID.map { [$0] } ?? [])
  }

  func testStructuredSourceLinkParsesDeterministicMilliseconds() throws {
    let url = try XCTUnwrap(URL(string: "speakenote://session#t=1250-3500"))
    let parsed = try XCTUnwrap(
      VoiceNoteCoordinator.structuredSourceStartTime(from: url)
    )

    XCTAssertEqual(
      parsed,
      1.25,
      accuracy: 0.000_1
    )
  }

  func testStructuredSourceLinkRejectsMalformedOrUnrelatedFragments() throws {
    let malformed = try XCTUnwrap(URL(string: "speakenote://session#t=-1-2"))
    let unrelated = try XCTUnwrap(URL(string: "speakenote://session#section"))

    XCTAssertNil(VoiceNoteCoordinator.structuredSourceStartTime(from: malformed))
    XCTAssertNil(VoiceNoteCoordinator.structuredSourceStartTime(from: unrelated))
  }

  func testStructuredRunsAreAppendOnlyAndCanBeSwitched() async throws {
    let session = makeSession(status: .completed)
    let repository = FakeVoiceNoteRepository(sessions: [session])
    let structured = FakeCoordinatorStructuredWorkflow()
    let coordinator = VoiceNoteCoordinator(
      sessionRepository: repository,
      settingsRepository: VoiceNoteCoordinatorSettingsRepository(),
      workflow: FakeVoiceNoteWorkflow(repository: repository),
      filePicker: FakeVoiceNoteFilePicker(),
      structuredWorkflow: structured
    )
    await coordinator.load()
    await coordinator.select(session.id)

    coordinator.selectedNoteType = .classNotes
    await coordinator.generateStructuredNote()
    let firstID = try XCTUnwrap(coordinator.selectedStructuredRunID)
    coordinator.selectedNoteType = .generalNotes
    await coordinator.generateStructuredNote()
    let secondID = try XCTUnwrap(coordinator.selectedStructuredRunID)

    XCTAssertNotEqual(firstID, secondID)
    XCTAssertEqual(coordinator.structuredRuns.count, 2)
    XCTAssertEqual(coordinator.structuredDocument?.noteType, .generalNotes)

    await coordinator.selectStructuredRun(firstID)

    XCTAssertEqual(coordinator.structuredDocument?.noteType, .classNotes)
    XCTAssertTrue(coordinator.structuredMarkdown?.contains("Class Notes") == true)
    let processedNoteTypes = await structured.processedNoteTypes
    XCTAssertEqual(
      processedNoteTypes,
      [.classNotes, .generalNotes]
    )
  }

  private func makeCoordinator(
    repository: FakeVoiceNoteRepository,
    workflow: FakeVoiceNoteWorkflow? = nil,
    settings: AppSettings = .defaultValue
  ) -> VoiceNoteCoordinator {
    VoiceNoteCoordinator(
      sessionRepository: repository,
      settingsRepository: VoiceNoteCoordinatorSettingsRepository(settings),
      workflow: workflow ?? FakeVoiceNoteWorkflow(repository: repository),
      filePicker: FakeVoiceNoteFilePicker()
    )
  }
}

private actor VoiceNoteCoordinatorSettingsRepository: SettingsStoring {
  private var settings: AppSettings

  init(_ settings: AppSettings = .defaultValue) {
    self.settings = settings
  }

  func load() -> AppSettings {
    settings
  }

  func save(_ settings: AppSettings) {
    self.settings = settings
  }

  func reset() {
    settings = .defaultValue
  }
}

@MainActor
private final class FakeVoiceNoteFilePicker: VoiceNoteFilePicking {
  private let url: URL?

  init(url: URL? = nil) {
    self.url = url
  }

  func chooseAudioFile() async -> URL? {
    url
  }
}

private enum FakeVoiceNoteWorkflowFailure: Error, Equatable {
  case importFile
  case resume
  case delete
}

private actor FakeVoiceNoteWorkflow: VoiceNoteWorkflowRunning {
  struct ImportRequest: Sendable {
    let url: URL
    let title: String?
  }

  private let repository: FakeVoiceNoteRepository
  private let importedSessionID: UUID
  private var failure: FakeVoiceNoteWorkflowFailure?
  private(set) var importRequests: [ImportRequest] = []
  private(set) var resumeIDs: [UUID] = []
  private(set) var cancelIDs: [UUID] = []
  private(set) var deleteIDs: [UUID] = []

  init(
    repository: FakeVoiceNoteRepository,
    importedSessionID: UUID = UUID()
  ) {
    self.repository = repository
    self.importedSessionID = importedSessionID
  }

  func setFailure(_ failure: FakeVoiceNoteWorkflowFailure?) {
    self.failure = failure
  }

  func importAndStart(url: URL, title: String?) async throws -> UUID {
    guard failure != .importFile else {
      throw FakeVoiceNoteWorkflowFailure.importFile
    }
    importRequests.append(ImportRequest(url: url, title: title))
    await repository.insert(
      makeSession(
        id: importedSessionID,
        title: title ?? url.deletingPathExtension().lastPathComponent,
        status: .transcribing
      )
    )
    return importedSessionID
  }

  func resume(sessionID: UUID) async throws {
    guard failure != .resume else {
      throw FakeVoiceNoteWorkflowFailure.resume
    }
    resumeIDs.append(sessionID)
  }

  func cancel(sessionID: UUID) async {
    cancelIDs.append(sessionID)
  }

  func delete(sessionID: UUID) async throws {
    guard failure != .delete else {
      throw FakeVoiceNoteWorkflowFailure.delete
    }
    deleteIDs.append(sessionID)
    await repository.removeSession(id: sessionID)
  }
}

private actor FakeCoordinatorStructuredWorkflow:
  VoiceNoteStructuredProcessingRunning
{
  private var stored: [VoiceNoteStructuredRun] = []
  private(set) var processedNoteTypes: [NoteType] = []

  func process(
    sessionID: UUID,
    noteType: NoteType
  ) async throws -> VoiceNoteStructuredRun {
    processedNoteTypes.append(noteType)
    let index = stored.count + 1
    let id = UUID(
      uuidString: String(
        format: "00000000-0000-0000-0000-%012d",
        2_000 + index
      )
    )!
    let document = ProcessedDocument(
      noteType: noteType,
      title: noteType == .classNotes ? "Class Notes" : "General Notes",
      summary: "Summary",
      sections: [],
      keyPoints: [],
      actions: [],
      openQuestions: [],
      sourceRanges: [StructuredSourceRange(startTime: 0, endTime: 1)],
      lecture: noteType == .classNotes ? LectureNoteFields() : nil,
      meeting: noteType == .meetingMinutes ? MeetingNoteFields() : nil
    )
    let markdown = StructuredNoteMarkdownRenderer().render(document)
    let run = ProcessingRunDTO(
      id: id,
      ownerKind: .voiceNote,
      ownerID: sessionID,
      createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
      providerID: "fake",
      modelID: "fake-model",
      configurationHash: "hash-\(index)",
      outputText: markdown,
      status: .succeeded,
      errorCategory: nil
    )
    let output = VoiceNoteStructuredRun(
      run: run,
      document: document,
      markdown: markdown
    )
    stored.append(output)
    return output
  }

  func runs(sessionID: UUID) async throws -> [ProcessingRunDTO] {
    stored.filter { $0.run.ownerID == sessionID }.map(\.run)
  }

  func read(
    sessionID: UUID,
    runID: UUID
  ) async throws -> VoiceNoteStructuredRun? {
    stored.first { $0.run.ownerID == sessionID && $0.run.id == runID }
  }
}

private actor FakeCoordinatorRecordingWorkflow: VoiceNoteRecordingRunning {
  nonisolated let events: AsyncStream<VoiceNoteRecordingWorkflowEvent>

  private let repository: FakeVoiceNoteRepository
  private let continuation: AsyncStream<VoiceNoteRecordingWorkflowEvent>.Continuation
  private var sessionID: UUID?
  private(set) var pauseCount = 0
  private(set) var resumeCount = 0
  private(set) var cancelCount = 0
  private(set) var recoverIDs: [UUID] = []
  private(set) var keepIDs: [UUID] = []

  init(repository: FakeVoiceNoteRepository) {
    let stream = AsyncStream<VoiceNoteRecordingWorkflowEvent>.makeStream()
    events = stream.stream
    continuation = stream.continuation
    self.repository = repository
  }

  func start(title: String?) async throws -> UUID {
    let id = UUID()
    sessionID = id
    await repository.insert(
      RecordingSessionDTO(
        id: id,
        title: title ?? "New Recording",
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1),
        source: .recorded,
        status: .recording,
        duration: 0,
        currentJobID: nil,
        needsRepair: false
      )
    )
    continuation.yield(
      .stateChanged(
        .recording(sessionID: id, startedAt: Date(timeIntervalSince1970: 1))
      )
    )
    return id
  }

  func pause() async throws {
    let id = try activeID()
    pauseCount += 1
    _ = try await repository.updateSession(
      id: id,
      status: .paused,
      duration: 0,
      currentJobID: nil,
      updatedAt: Date()
    )
    continuation.yield(
      .stateChanged(
        .paused(sessionID: id, startedAt: Date(timeIntervalSince1970: 1))
      )
    )
  }

  func resume() async throws {
    let id = try activeID()
    resumeCount += 1
    _ = try await repository.updateSession(
      id: id,
      status: .recording,
      duration: 0,
      currentJobID: nil,
      updatedAt: Date()
    )
    continuation.yield(
      .stateChanged(
        .recording(sessionID: id, startedAt: Date(timeIntervalSince1970: 1))
      )
    )
  }

  func stopAndProcess() async throws {
    let id = try activeID()
    _ = try await repository.updateSession(
      id: id,
      status: .preprocessing,
      duration: 1,
      currentJobID: nil,
      updatedAt: Date()
    )
    sessionID = nil
    continuation.yield(.stateChanged(.processing(sessionID: id)))
  }

  func cancelPreservingAudio() async {
    guard let id = sessionID else { return }
    cancelCount += 1
    _ = try? await repository.updateSession(
      id: id,
      status: .recoveryAvailable,
      duration: 1,
      currentJobID: nil,
      updatedAt: Date()
    )
    sessionID = nil
    continuation.yield(.stateChanged(.recoveryAvailable(sessionID: id)))
  }

  func interrupt(reason: M4RecordingInterruptionReason) async {
    await cancelPreservingAudio()
  }

  func recoverAndProcess(sessionID: UUID) async throws {
    recoverIDs.append(sessionID)
    _ = try await repository.updateSession(
      id: sessionID,
      status: .preprocessing,
      duration: 1,
      currentJobID: nil,
      updatedAt: Date()
    )
  }

  func keepRecoveredAudio(sessionID: UUID) async throws {
    keepIDs.append(sessionID)
    _ = try await repository.updateSession(
      id: sessionID,
      status: .interrupted,
      duration: 1,
      currentJobID: nil,
      updatedAt: Date()
    )
  }

  private func activeID() throws -> UUID {
    guard let sessionID else {
      throw VoiceNoteRecordingWorkflowError.noActiveRecording
    }
    return sessionID
  }
}

private actor FakeCoordinatorRecoveryManager: VoiceNoteRecoveryManaging {
  private(set) var reconcileCount = 0

  func reconcile() -> [VoiceNoteRecoveryCandidate] {
    reconcileCount += 1
    return []
  }

  func candidate(sessionID: UUID) throws -> VoiceNoteRecoveryCandidate {
    throw VoiceNoteRecoveryError.noRecoverableAudio
  }

  func keepAudio(sessionID: UUID) {}

  func playbackSegments(sessionID: UUID) throws -> [M4RecordingSegment] {
    throw VoiceNoteRecoveryError.noRecoverableAudio
  }
}

private actor FakeVoiceNoteRepository: VoiceNoteSessionStoring {
  private var storedSessions: [RecordingSessionDTO]
  private var storedJobs: [TranscriptionJobDTO]
  private(set) var sessionsCallCount = 0

  init(
    sessions: [RecordingSessionDTO] = [],
    jobs: [TranscriptionJobDTO] = []
  ) {
    storedSessions = sessions
    storedJobs = jobs
  }

  func insert(_ session: RecordingSessionDTO) {
    storedSessions.append(session)
  }

  func removeSession(id: UUID) {
    storedSessions.removeAll { $0.id == id }
    storedJobs.removeAll { $0.sessionID == id }
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
    sessionsCallCount += 1
    return storedSessions
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
    replace(updated)
    return updated
  }

  func renameSession(
    id: UUID,
    title: String,
    updatedAt: Date
  ) throws -> RecordingSessionDTO {
    guard let current = storedSessions.first(where: { $0.id == id }) else {
      throw SessionRepositoryError.sessionNotFound(id)
    }
    let updated = RecordingSessionDTO(
      id: current.id,
      title: title,
      createdAt: current.createdAt,
      updatedAt: updatedAt,
      source: current.source,
      status: current.status,
      duration: current.duration,
      currentJobID: current.currentJobID,
      needsRepair: current.needsRepair
    )
    replace(updated)
    return updated
  }

  func markSessionNeedsRepair(
    id: UUID,
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
      status: .needsRepair,
      duration: current.duration,
      currentJobID: current.currentJobID,
      needsRepair: true
    )
    replace(updated)
    return updated
  }

  func createJob(_ job: NewTranscriptionJob) throws -> TranscriptionJobDTO {
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
    guard let current = storedJobs.first(where: { $0.id == id }) else {
      throw SessionRepositoryError.jobNotFound(id)
    }
    let updated = TranscriptionJobDTO(
      id: current.id,
      sessionID: current.sessionID,
      createdAt: current.createdAt,
      updatedAt: updatedAt,
      stage: stage,
      completedChunks: completedChunks,
      totalChunks: totalChunks,
      checkpointRelativePath: checkpointRelativePath,
      errorCategory: errorCategory
    )
    storedJobs.removeAll { $0.id == id }
    storedJobs.append(updated)
    return updated
  }

  func deleteSessionMetadata(id: UUID) throws {
    removeSession(id: id)
  }

  private func replace(_ session: RecordingSessionDTO) {
    storedSessions.removeAll { $0.id == session.id }
    storedSessions.append(session)
  }
}

private func makeSession(
  id: UUID = UUID(),
  title: String = "Meeting",
  status: VoiceNoteSessionStatus = .ready,
  currentJobID: UUID? = nil
) -> RecordingSessionDTO {
  RecordingSessionDTO(
    id: id,
    title: title,
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 2),
    source: .imported,
    status: status,
    duration: 90,
    currentJobID: currentJobID,
    needsRepair: status == .needsRepair
  )
}

private func makeJob(
  id: UUID = UUID(),
  sessionID: UUID,
  completedChunks: Int = 0,
  totalChunks: Int = 0
) -> TranscriptionJobDTO {
  TranscriptionJobDTO(
    id: id,
    sessionID: sessionID,
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 2),
    stage: .transcribing,
    completedChunks: completedChunks,
    totalChunks: totalChunks,
    checkpointRelativePath: "checkpoints/job.json",
    errorCategory: nil
  )
}

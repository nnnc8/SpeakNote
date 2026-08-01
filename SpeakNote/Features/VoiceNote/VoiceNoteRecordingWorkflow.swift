import Foundation

enum VoiceNoteRecordingWorkflowState: Equatable, Sendable {
  case idle
  case preparing(sessionID: UUID)
  case recording(sessionID: UUID, startedAt: Date)
  case paused(sessionID: UUID, startedAt: Date)
  case finalizing(sessionID: UUID)
  case processing(sessionID: UUID)
  case recoveryAvailable(sessionID: UUID)
  case failed(sessionID: UUID?)
}

enum VoiceNoteRecordingWorkflowEvent: Equatable, Sendable {
  case stateChanged(VoiceNoteRecordingWorkflowState)
  case meter(M4RecordingMeter)
  case segmentCommitted(index: Int, duration: TimeInterval)
  case lowDiskWarning
}

enum VoiceNoteRecordingWorkflowError: Error, Equatable, Sendable {
  case alreadyActive
  case noActiveRecording
  case sessionNotFound
  case noRecoverableSegments
  case persistenceFailure
  case insufficientDiskSpace
}

protocol VoiceNoteRecordingRunning: Actor {
  var events: AsyncStream<VoiceNoteRecordingWorkflowEvent> { get }

  func start(title: String?) async throws -> UUID
  func pause() async throws
  func resume() async throws
  func stopAndProcess() async throws
  func cancelPreservingAudio() async
  func interrupt(reason: M4RecordingInterruptionReason) async
  func recoverAndProcess(sessionID: UUID) async throws
  func keepRecoveredAudio(sessionID: UUID) async throws
}

actor VoiceNoteRecordingWorkflow: VoiceNoteRecordingRunning {
  static let defaultSegmentDuration: TimeInterval = 5 * 60
  static let defaultJournalInterval: TimeInterval = 10

  nonisolated let events: AsyncStream<VoiceNoteRecordingWorkflowEvent>

  private let repository: any VoiceNoteSessionStoring
  private let fileStore: SessionFileStore
  private let recorder: any M4RollingSegmentRecording
  private let archiveBuilder: any M4AudioArchiving
  private let processingStarter: any VoiceNoteRecordedProcessingStarting
  private let recoveryManager: any VoiceNoteRecoveryManaging
  private let diskCapacityChecker: any DiskCapacityChecking
  private let minimumAvailableDiskCapacityBytes: Int64
  private let segmentDuration: TimeInterval
  private let journalInterval: TimeInterval
  private let now: @Sendable () -> Date
  private let eventContinuation: AsyncStream<VoiceNoteRecordingWorkflowEvent>.Continuation

  private var activeSessionID: UUID?
  private var recordingStartedAt: Date?
  private var lastClosedSegmentIndex: Int?
  private var recordedDuration: TimeInterval = 0
  private var recorderEventTask: Task<Void, Never>?
  private var journalTask: Task<Void, Never>?

  init(
    repository: any VoiceNoteSessionStoring,
    fileStore: SessionFileStore,
    recorder: any M4RollingSegmentRecording,
    archiveBuilder: any M4AudioArchiving,
    processingStarter: any VoiceNoteRecordedProcessingStarting,
    recoveryManager: any VoiceNoteRecoveryManaging,
    diskCapacityChecker: any DiskCapacityChecking = VolumeDiskCapacityChecker(),
    minimumAvailableDiskCapacityBytes: Int64 = 512 * 1_024 * 1_024,
    segmentDuration: TimeInterval = defaultSegmentDuration,
    journalInterval: TimeInterval = defaultJournalInterval,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    let stream = AsyncStream<VoiceNoteRecordingWorkflowEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(256)
    )
    events = stream.stream
    eventContinuation = stream.continuation
    self.repository = repository
    self.fileStore = fileStore
    self.recorder = recorder
    self.archiveBuilder = archiveBuilder
    self.processingStarter = processingStarter
    self.recoveryManager = recoveryManager
    self.diskCapacityChecker = diskCapacityChecker
    self.minimumAvailableDiskCapacityBytes =
      minimumAvailableDiskCapacityBytes
    self.segmentDuration = segmentDuration
    self.journalInterval = journalInterval
    self.now = now
  }

  deinit {
    eventContinuation.finish()
  }

  func start(title: String?) async throws -> UUID {
    guard activeSessionID == nil else {
      throw VoiceNoteRecordingWorkflowError.alreadyActive
    }
    guard segmentDuration.isFinite, segmentDuration > 0,
      journalInterval.isFinite, journalInterval > 0
    else {
      throw VoiceNoteRecordingWorkflowError.persistenceFailure
    }
    let sessionID = UUID()
    let startedAt = now()
    setState(.preparing(sessionID: sessionID))
    _ = try await fileStore.prepareSession(
      id: sessionID,
      source: .recorded,
      createdAt: startedAt
    )

    do {
      _ = try await repository.createSession(
        NewRecordingSession(
          id: sessionID,
          title: Self.resolvedTitle(title),
          createdAt: startedAt,
          source: .recorded,
          status: .recording,
          duration: 0
        )
      )
      try await fileStore.writeRecordingJournal(
        RecordingJournal(
          sessionID: sessionID,
          startedAt: startedAt,
          segmentDuration: segmentDuration,
          state: .recording
        )
      )
      let audioDirectory = try await fileStore.fileURL(
        sessionID: sessionID,
        relativePath: "audio"
      )
      try await requireAvailableDiskCapacity(at: audioDirectory)
      try await recorder.start(sessionID: sessionID, directory: audioDirectory)
      activeSessionID = sessionID
      recordingStartedAt = startedAt
      lastClosedSegmentIndex = nil
      recordedDuration = 0
      recorderEventTask = Task {
        await consumeRecorderEvents(sessionID: sessionID)
      }
      journalTask = Task {
        await runJournalTimer(sessionID: sessionID)
      }
      setState(.recording(sessionID: sessionID, startedAt: startedAt))
      return sessionID
    } catch let operationError {
      try? await fileStore.clearRecordingJournal(sessionID: sessionID)
      do {
        try await fileStore.removeSession(sessionID: sessionID)
        try? await repository.deleteSessionMetadata(id: sessionID)
      } catch {
        _ = try? await repository.markSessionNeedsRepair(
          id: sessionID,
          updatedAt: now()
        )
      }
      resetActiveRecording()
      setState(.failed(sessionID: sessionID))
      throw operationError
    }
  }

  func pause() async throws {
    guard let sessionID = activeSessionID,
      let startedAt = recordingStartedAt
    else {
      throw VoiceNoteRecordingWorkflowError.noActiveRecording
    }
    try await recorder.pause()
    _ = try await repository.updateSession(
      id: sessionID,
      status: .paused,
      duration: recordedDuration,
      currentJobID: nil,
      updatedAt: now()
    )
    try await updateJournal(sessionID: sessionID, state: .paused)
    setState(.paused(sessionID: sessionID, startedAt: startedAt))
  }

  func resume() async throws {
    guard let sessionID = activeSessionID,
      let startedAt = recordingStartedAt
    else {
      throw VoiceNoteRecordingWorkflowError.noActiveRecording
    }
    let audioDirectory = try await fileStore.fileURL(
      sessionID: sessionID,
      relativePath: "audio"
    )
    try await requireAvailableDiskCapacity(at: audioDirectory)
    try await recorder.resume()
    _ = try await repository.updateSession(
      id: sessionID,
      status: .recording,
      duration: recordedDuration,
      currentJobID: nil,
      updatedAt: now()
    )
    try await updateJournal(sessionID: sessionID, state: .recording)
    setState(.recording(sessionID: sessionID, startedAt: startedAt))
  }

  func stopAndProcess() async throws {
    guard let sessionID = activeSessionID else {
      throw VoiceNoteRecordingWorkflowError.noActiveRecording
    }
    setState(.finalizing(sessionID: sessionID))
    stopJournalTimer()
    do {
      let result = try await recorder.stop()
      stopRecorderEventTask()
      let archive = try await finalize(
        sessionID: sessionID,
        segments: result.segments
      )
      try await fileStore.clearRecordingJournal(sessionID: sessionID)
      _ = try await repository.updateSession(
        id: sessionID,
        status: .ready,
        duration: archive.duration,
        currentJobID: nil,
        updatedAt: now()
      )
      try await processingStarter.startRecordedProcessing(
        sessionID: sessionID,
        sourceRelativePath: "audio/archive.m4a",
        duration: archive.duration
      )
      resetActiveRecording()
      setState(.processing(sessionID: sessionID))
    } catch {
      await preserveForRecovery(sessionID: sessionID)
      throw error
    }
  }

  func cancelPreservingAudio() async {
    guard let sessionID = activeSessionID else { return }
    await interruptAndPreserve(sessionID: sessionID, reason: .userRequested)
  }

  func interrupt(reason: M4RecordingInterruptionReason) async {
    guard let sessionID = activeSessionID else { return }
    await interruptAndPreserve(sessionID: sessionID, reason: reason)
  }

  func recoverAndProcess(sessionID: UUID) async throws {
    let candidate = try await recoveryManager.candidate(sessionID: sessionID)
    setState(.finalizing(sessionID: sessionID))
    do {
      let manifest = try await fileStore.manifest(sessionID: sessionID)
      let archive: M4AudioArchive
      if let existing = manifest.assets.first(where: {
        $0.kind == .archive && $0.relativePath == "audio/archive.m4a"
      }) {
        let destination = try await fileStore.fileURL(
          sessionID: sessionID,
          relativePath: existing.relativePath
        )
        _ = try await fileStore.registerExistingAsset(
          sessionID: sessionID,
          relativePath: existing.relativePath,
          kind: .archive,
          expectedSHA256: existing.sha256,
          expectedByteCount: existing.byteCount,
          createdAt: existing.createdAt
        )
        let duration = max(
          candidate.session.duration,
          candidate.completeSegments.last?.endTime ?? 0
        )
        guard duration > 0 else {
          throw VoiceNoteRecordingWorkflowError.persistenceFailure
        }
        archive = M4AudioArchive(
          url: destination,
          duration: duration,
          byteCount: existing.byteCount,
          sha256: existing.sha256
        )
        try await fileStore.removeAssets(
          sessionID: sessionID,
          kind: .captureSegment,
          at: now()
        )
      } else {
        guard !candidate.completeSegments.isEmpty else {
          throw VoiceNoteRecordingWorkflowError.noRecoverableSegments
        }
        archive = try await finalize(
          sessionID: sessionID,
          segments: candidate.completeSegments
        )
      }
      if let journal = try await fileStore.recordingJournal(),
        journal.sessionID == sessionID
      {
        try await fileStore.clearRecordingJournal(sessionID: sessionID)
      }
      _ = try await repository.updateSession(
        id: sessionID,
        status: .ready,
        duration: archive.duration,
        currentJobID: nil,
        updatedAt: now()
      )
      try await processingStarter.startRecordedProcessing(
        sessionID: sessionID,
        sourceRelativePath: "audio/archive.m4a",
        duration: archive.duration
      )
      setState(.processing(sessionID: sessionID))
    } catch {
      await preserveForRecovery(sessionID: sessionID)
      throw error
    }
  }

  func keepRecoveredAudio(sessionID: UUID) async throws {
    try await recoveryManager.keepAudio(sessionID: sessionID)
    setState(.recoveryAvailable(sessionID: sessionID))
  }

  private func consumeRecorderEvents(sessionID: UUID) async {
    for await event in recorder.events {
      guard !Task.isCancelled, activeSessionID == sessionID else { return }
      switch event {
      case .meter(let meter):
        eventContinuation.yield(.meter(meter))
      case .segmentClosed(let segment):
        do {
          try await commit(segment, sessionID: sessionID)
        } catch {
          await recorder.interrupt(reason: .systemInterruption)
          await preserveForRecovery(sessionID: sessionID)
          return
        }
      case .stateChanged(.interrupted(_, .deviceLost)):
        await interruptAndPreserve(
          sessionID: sessionID,
          reason: .deviceLost
        )
        return
      case .stateChanged(.failed(_, let failure)):
        await preserveForRecovery(sessionID: sessionID)
        if case .diskWriteFailed = failure {
          eventContinuation.yield(.lowDiskWarning)
        }
        return
      case .stateChanged:
        break
      }
    }
  }

  private func commit(
    _ segment: M4RecordingSegment,
    sessionID: UUID
  ) async throws {
    guard segment.sessionID == sessionID else {
      throw VoiceNoteRecordingWorkflowError.persistenceFailure
    }
    _ = try await fileStore.registerExistingAsset(
      sessionID: sessionID,
      relativePath: "audio/\(segment.relativePath)",
      kind: .captureSegment,
      expectedSHA256: segment.sha256,
      expectedByteCount: segment.byteCount,
      createdAt: segment.createdAt
    )
    lastClosedSegmentIndex = max(lastClosedSegmentIndex ?? -1, segment.index)
    recordedDuration = max(recordedDuration, segment.endTime)
    if activeSessionID == sessionID {
      _ = try await repository.updateSession(
        id: sessionID,
        status: .recording,
        duration: recordedDuration,
        currentJobID: nil,
        updatedAt: now()
      )
      try await updateJournal(sessionID: sessionID, state: .recording)
    }
    eventContinuation.yield(
      .segmentCommitted(index: segment.index, duration: recordedDuration)
    )
  }

  private func finalize(
    sessionID: UUID,
    segments: [M4RecordingSegment]
  ) async throws -> M4AudioArchive {
    guard !segments.isEmpty else {
      throw VoiceNoteRecordingWorkflowError.noRecoverableSegments
    }
    for segment in segments {
      try await commit(segment, sessionID: sessionID)
    }
    let manifest = try await fileStore.manifest(sessionID: sessionID)
    let destination = try await fileStore.fileURL(
      sessionID: sessionID,
      relativePath: "audio/archive.m4a"
    )
    if let existing = manifest.assets.first(where: {
      $0.kind == .archive && $0.relativePath == "audio/archive.m4a"
    }) {
      _ = try await fileStore.registerExistingAsset(
        sessionID: sessionID,
        relativePath: existing.relativePath,
        kind: .archive,
        expectedSHA256: existing.sha256,
        expectedByteCount: existing.byteCount,
        createdAt: existing.createdAt
      )
      let duration = segments.last?.endTime ?? recordedDuration
      try await fileStore.removeAssets(
        sessionID: sessionID,
        kind: .captureSegment,
        at: now()
      )
      return M4AudioArchive(
        url: destination,
        duration: duration,
        byteCount: existing.byteCount,
        sha256: existing.sha256
      )
    }

    // A crash can occur after the archive rename but before manifest commit.
    // The immutable capture segments are still authoritative, so rebuild it.
    try await fileStore.removeUnregisteredFile(
      sessionID: sessionID,
      relativePath: "audio/archive.m4a"
    )
    let archive = try await archiveBuilder.buildArchive(
      segments: segments,
      destinationURL: destination
    )
    _ = try await fileStore.registerExistingAsset(
      sessionID: sessionID,
      relativePath: "audio/archive.m4a",
      kind: .archive,
      expectedSHA256: archive.sha256,
      expectedByteCount: archive.byteCount,
      createdAt: now()
    )
    try await fileStore.removeAssets(
      sessionID: sessionID,
      kind: .captureSegment,
      at: now()
    )
    return archive
  }

  private func interruptAndPreserve(
    sessionID: UUID,
    reason: M4RecordingInterruptionReason
  ) async {
    stopJournalTimer()
    await recorder.interrupt(reason: reason)
    let result = try? await recorder.stop()
    stopRecorderEventTask()
    if let result {
      for segment in result.segments {
        try? await commit(segment, sessionID: sessionID)
      }
    }
    await preserveForRecovery(sessionID: sessionID)
  }

  private func preserveForRecovery(sessionID: UUID) async {
    stopJournalTimer()
    stopRecorderEventTask()
    try? await updateJournal(sessionID: sessionID, state: .interrupted)
    try? await fileStore.updateState(
      sessionID: sessionID,
      state: .interrupted,
      at: now()
    )
    _ = try? await repository.updateSession(
      id: sessionID,
      status: .recoveryAvailable,
      duration: recordedDuration,
      currentJobID: nil,
      updatedAt: now()
    )
    resetActiveRecording()
    setState(.recoveryAvailable(sessionID: sessionID))
  }

  private func runJournalTimer(sessionID: UUID) async {
    while !Task.isCancelled, activeSessionID == sessionID {
      do {
        try await Task.sleep(for: .seconds(journalInterval))
      } catch {
        return
      }
      guard !Task.isCancelled, activeSessionID == sessionID else { return }
      do {
        let audioDirectory = try await fileStore.fileURL(
          sessionID: sessionID,
          relativePath: "audio"
        )
        try await requireAvailableDiskCapacity(at: audioDirectory)
      } catch let error as VoiceNoteRecordingWorkflowError
        where error == .insufficientDiskSpace
      {
        await interruptAndPreserve(
          sessionID: sessionID,
          reason: .systemInterruption
        )
        eventContinuation.yield(.lowDiskWarning)
        return
      } catch {
        await interruptAndPreserve(
          sessionID: sessionID,
          reason: .systemInterruption
        )
        return
      }
      try? await updateJournal(sessionID: sessionID, state: .recording)
    }
  }

  private func updateJournal(
    sessionID: UUID,
    state: RecordingJournal.State
  ) async throws {
    guard let startedAt = recordingStartedAt else {
      throw VoiceNoteRecordingWorkflowError.noActiveRecording
    }
    try await fileStore.writeRecordingJournal(
      RecordingJournal(
        sessionID: sessionID,
        startedAt: startedAt,
        updatedAt: now(),
        segmentDuration: segmentDuration,
        lastClosedSegmentIndex: lastClosedSegmentIndex,
        state: state
      )
    )
  }

  private func requireAvailableDiskCapacity(at url: URL) async throws {
    guard minimumAvailableDiskCapacityBytes > 0 else {
      throw VoiceNoteRecordingWorkflowError.persistenceFailure
    }
    let available = try await diskCapacityChecker.availableCapacity(at: url)
    guard available >= minimumAvailableDiskCapacityBytes else {
      throw VoiceNoteRecordingWorkflowError.insufficientDiskSpace
    }
  }

  private func stopJournalTimer() {
    journalTask?.cancel()
    journalTask = nil
  }

  private func stopRecorderEventTask() {
    recorderEventTask?.cancel()
    recorderEventTask = nil
  }

  private func resetActiveRecording() {
    stopJournalTimer()
    stopRecorderEventTask()
    activeSessionID = nil
    recordingStartedAt = nil
    lastClosedSegmentIndex = nil
    recordedDuration = 0
  }

  private func setState(_ state: VoiceNoteRecordingWorkflowState) {
    eventContinuation.yield(.stateChanged(state))
  }

  private static func resolvedTitle(_ title: String?) -> String {
    let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return title.isEmpty ? String(localized: "New Recording") : title
  }
}

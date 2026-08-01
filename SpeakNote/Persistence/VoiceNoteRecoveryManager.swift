import Foundation

struct VoiceNoteRecoveryCandidate: Equatable, Identifiable, Sendable {
  var id: UUID { session.id }

  let session: RecordingSessionDTO
  let completeSegments: [M4RecordingSegment]
  let incompleteCurrentSegment: M4IncompleteRecordingSegment?
  let issues: [M4RecordingRecoveryIssue]
}

enum VoiceNoteRecoveryError: Error, Equatable, Sendable {
  case sessionNotFound
  case manifestNotFound
  case noRecoverableAudio
}

protocol VoiceNoteRecoveryManaging: Actor {
  func reconcile() async throws -> [VoiceNoteRecoveryCandidate]
  func candidate(sessionID: UUID) async throws -> VoiceNoteRecoveryCandidate
  func keepAudio(sessionID: UUID) async throws
  func playbackSegments(sessionID: UUID) async throws -> [M4RecordingSegment]
}

actor VoiceNoteRecoveryManager: VoiceNoteRecoveryManaging {
  private let repository: any VoiceNoteSessionStoring
  private let fileStore: SessionFileStore
  private let recordingRecovery: M4RecordingRecovery
  private let structuredRunReconciler: (any M5StructuredRunReconciling)?
  private let now: @Sendable () -> Date

  init(
    repository: any VoiceNoteSessionStoring,
    fileStore: SessionFileStore,
    recordingRecovery: M4RecordingRecovery = M4RecordingRecovery(),
    structuredRunReconciler: (any M5StructuredRunReconciling)? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.repository = repository
    self.fileStore = fileStore
    self.recordingRecovery = recordingRecovery
    self.structuredRunReconciler = structuredRunReconciler
    self.now = now
  }

  func reconcile() async throws -> [VoiceNoteRecoveryCandidate] {
    let fileSessionIDs = Set(try await fileStore.sessionIDs())
    var databaseSessions = try await repository.sessions()
    let databaseSessionIDs = Set(databaseSessions.map(\.id))

    for session in databaseSessions where !fileSessionIDs.contains(session.id) {
      _ = try await repository.markSessionNeedsRepair(
        id: session.id,
        updatedAt: now()
      )
    }

    for sessionID in fileSessionIDs.subtracting(databaseSessionIDs) {
      let manifest = try await fileStore.manifest(sessionID: sessionID)
      let source: VoiceNoteSource =
        manifest.source == .recorded ? .recorded : .imported
      _ = try await repository.createSession(
        NewRecordingSession(
          id: sessionID,
          title: String(localized: "Recovered Voice Note"),
          createdAt: manifest.createdAt,
          source: source,
          status: source == .recorded ? .recoveryAvailable : .needsRepair,
          duration: 0
        )
      )
    }
    databaseSessions = try await repository.sessions()
    try await structuredRunReconciler?.reconcileM5StructuredRuns()

    let journal = try await fileStore.recordingJournal()
    var candidates: [VoiceNoteRecoveryCandidate] = []
    for session in databaseSessions {
      guard fileSessionIDs.contains(session.id), session.source == .recorded else {
        continue
      }
      let shouldRecover =
        journal?.sessionID == session.id
        || session.status == .recording
        || session.status == .paused
        || session.status == .recoveryAvailable
        || session.status == .interrupted
      guard shouldRecover else { continue }

      let recovered = try await recover(session: session)
      candidates.append(recovered)
    }
    return candidates.sorted {
      if $0.session.updatedAt != $1.session.updatedAt {
        return $0.session.updatedAt > $1.session.updatedAt
      }
      return $0.id.uuidString < $1.id.uuidString
    }
  }

  func candidate(sessionID: UUID) async throws -> VoiceNoteRecoveryCandidate {
    guard let session = try await repository.session(id: sessionID) else {
      throw VoiceNoteRecoveryError.sessionNotFound
    }
    guard session.source == .recorded else {
      throw VoiceNoteRecoveryError.noRecoverableAudio
    }
    return try await recover(session: session)
  }

  func keepAudio(sessionID: UUID) async throws {
    guard let session = try await repository.session(id: sessionID) else {
      throw VoiceNoteRecoveryError.sessionNotFound
    }
    if let journal = try await fileStore.recordingJournal(),
      journal.sessionID == sessionID
    {
      try await fileStore.clearRecordingJournal(sessionID: sessionID)
    }
    _ = try await repository.updateSession(
      id: sessionID,
      status: .interrupted,
      duration: session.duration,
      currentJobID: session.currentJobID,
      updatedAt: now()
    )
    try await fileStore.updateState(
      sessionID: sessionID,
      state: .interrupted,
      at: now()
    )
  }

  func playbackSegments(sessionID: UUID) async throws -> [M4RecordingSegment] {
    guard let session = try await repository.session(id: sessionID) else {
      throw VoiceNoteRecoveryError.sessionNotFound
    }
    let manifest = try await fileStore.manifest(sessionID: sessionID)
    if let asset = manifest.assets.first(where: {
      $0.kind == .archive || $0.kind == .importedOriginal
    }) {
      guard session.duration.isFinite, session.duration > 0 else {
        throw VoiceNoteRecoveryError.noRecoverableAudio
      }
      let url = try await fileStore.fileURL(
        sessionID: sessionID,
        relativePath: asset.relativePath
      )
      return [
        M4RecordingSegment(
          sessionID: sessionID,
          index: 0,
          url: url,
          relativePath: asset.relativePath,
          startTime: 0,
          endTime: session.duration,
          byteCount: asset.byteCount,
          sha256: asset.sha256,
          createdAt: asset.createdAt
        )
      ]
    }

    guard session.source == .recorded else {
      throw VoiceNoteRecoveryError.noRecoverableAudio
    }
    let audioDirectory = try await fileStore.fileURL(
      sessionID: sessionID,
      relativePath: "audio"
    )
    let report = try await recordingRecovery.scan(
      sessionID: sessionID,
      directory: audioDirectory
    )
    guard !report.completeSegments.isEmpty else {
      throw VoiceNoteRecoveryError.noRecoverableAudio
    }
    return report.completeSegments
  }

  private func recover(
    session: RecordingSessionDTO
  ) async throws -> VoiceNoteRecoveryCandidate {
    let audioDirectory = try await fileStore.fileURL(
      sessionID: session.id,
      relativePath: "audio"
    )
    let report = try await recordingRecovery.scan(
      sessionID: session.id,
      directory: audioDirectory
    )
    for segment in report.completeSegments {
      _ = try await fileStore.registerExistingAsset(
        sessionID: session.id,
        relativePath: "audio/\(segment.relativePath)",
        kind: .captureSegment,
        expectedSHA256: segment.sha256,
        expectedByteCount: segment.byteCount,
        createdAt: segment.createdAt
      )
    }
    let duration = max(
      session.duration,
      max(
        report.completeSegments.last?.endTime ?? 0,
        report.incompleteCurrentSegment?.recoverableDuration ?? 0
      )
    )
    let recoveredSession = try await repository.updateSession(
      id: session.id,
      status: .recoveryAvailable,
      duration: duration,
      currentJobID: session.currentJobID,
      updatedAt: now()
    )
    try await fileStore.updateState(
      sessionID: session.id,
      state: .interrupted,
      at: now()
    )
    return VoiceNoteRecoveryCandidate(
      session: recoveredSession,
      completeSegments: report.completeSegments,
      incompleteCurrentSegment: report.incompleteCurrentSegment,
      issues: report.issues
    )
  }
}

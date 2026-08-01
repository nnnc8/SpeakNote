import Foundation

enum VoiceNoteWorkflowError: Error, Equatable, Sendable {
  case cloudProcessingConsentRequired
  case unsupportedProvider
  case sessionNotFound
  case jobNotFound
  case operationAlreadyRunning
  case invalidSessionSource
}

protocol VoiceNoteRecordedProcessingStarting: Actor {
  func startRecordedProcessing(
    sessionID: UUID,
    sourceRelativePath: String,
    duration: TimeInterval
  ) async throws
}

protocol VoiceNoteProviderFallbackRunning: Actor {
  func availableAlternativeProvider(sessionID: UUID) async throws -> ProviderID?
  func retry(sessionID: UUID, using providerID: ProviderID) async throws
}

actor VoiceNoteWorkflow:
  VoiceNoteWorkflowRunning,
  VoiceNoteRecordedProcessingStarting,
  VoiceNoteProviderFallbackRunning
{
  private let repository: any VoiceNoteSessionStoring
  private let settingsRepository: any SettingsStoring
  private let fileStore: SessionFileStore
  private let audioImporter: any AudioImporting
  private let pipeline: any VoiceNoteTranscriptionPipelining
  private let appleSpeechCapability: (any TranscriptionProviderCapabilityChecking)?
  private let vocabularyProcessor: (any VocabularyProcessing)?
  private let now: @Sendable () -> Date
  private var activeTasks: [UUID: Task<Void, Never>] = [:]

  init(
    repository: any VoiceNoteSessionStoring,
    settingsRepository: any SettingsStoring,
    fileStore: SessionFileStore,
    audioImporter: any AudioImporting,
    pipeline: any VoiceNoteTranscriptionPipelining,
    appleSpeechCapability:
      (any TranscriptionProviderCapabilityChecking)? = nil,
    vocabularyProcessor: (any VocabularyProcessing)? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.repository = repository
    self.settingsRepository = settingsRepository
    self.fileStore = fileStore
    self.audioImporter = audioImporter
    self.pipeline = pipeline
    self.appleSpeechCapability = appleSpeechCapability
    self.vocabularyProcessor = vocabularyProcessor
    self.now = now
  }

  func importAndStart(url: URL, title: String?) async throws -> UUID {
    let configuration = try await transcriptionConfiguration()
    let sessionID = UUID()
    let jobID = UUID()
    let createdAt = now()
    _ = try await fileStore.prepareSession(
      id: sessionID,
      source: .imported,
      createdAt: createdAt
    )

    do {
      let imported = try await audioImporter.importAudio(
        from: url,
        sessionID: sessionID
      )
      _ = try await repository.createSession(
        NewRecordingSession(
          id: sessionID,
          title: Self.resolvedTitle(title, sourceURL: url),
          createdAt: createdAt,
          source: .imported,
          status: .ready,
          duration: imported.duration
        )
      )
      _ = try await repository.createJob(
        NewTranscriptionJob(
          id: jobID,
          sessionID: sessionID,
          createdAt: createdAt
        )
      )
      _ = try await repository.updateSession(
        id: sessionID,
        status: .preprocessing,
        duration: imported.duration,
        currentJobID: jobID,
        updatedAt: now()
      )
      startTask(
        sessionID: sessionID,
        operation: { [pipeline] in
          try await pipeline.process(
            sessionID: sessionID,
            jobID: jobID,
            sourceRelativePath: imported.asset.relativePath,
            sourceDuration: imported.duration,
            configuration: configuration
          )
        }
      )
      return sessionID
    } catch let operationError {
      do {
        try await fileStore.removeSession(sessionID: sessionID)
        try? await repository.deleteSessionMetadata(id: sessionID)
      } catch {
        // Keep any created metadata when file cleanup fails so reconciliation can repair it.
      }
      throw operationError
    }
  }

  func resume(sessionID: UUID) async throws {
    guard activeTasks[sessionID] == nil else {
      throw VoiceNoteWorkflowError.operationAlreadyRunning
    }
    guard let session = try await repository.session(id: sessionID) else {
      throw VoiceNoteWorkflowError.sessionNotFound
    }
    guard let jobID = session.currentJobID,
      try await repository.job(id: jobID) != nil
    else {
      throw VoiceNoteWorkflowError.jobNotFound
    }
    let configuration = try await transcriptionConfiguration()
    startTask(
      sessionID: sessionID,
      operation: { [pipeline] in
        try await pipeline.resume(
          sessionID: sessionID,
          configuration: configuration
        )
      }
    )
  }

  func startRecordedProcessing(
    sessionID: UUID,
    sourceRelativePath: String,
    duration: TimeInterval
  ) async throws {
    guard activeTasks[sessionID] == nil else {
      throw VoiceNoteWorkflowError.operationAlreadyRunning
    }
    guard let session = try await repository.session(id: sessionID) else {
      throw VoiceNoteWorkflowError.sessionNotFound
    }
    guard session.source == .recorded else {
      throw VoiceNoteWorkflowError.invalidSessionSource
    }
    let configuration = try await transcriptionConfiguration()
    let jobID = UUID()
    _ = try await repository.createJob(
      NewTranscriptionJob(
        id: jobID,
        sessionID: sessionID,
        createdAt: now()
      )
    )
    _ = try await repository.updateSession(
      id: sessionID,
      status: .preprocessing,
      duration: duration,
      currentJobID: jobID,
      updatedAt: now()
    )
    startTask(
      sessionID: sessionID,
      operation: { [pipeline] in
        try await pipeline.process(
          sessionID: sessionID,
          jobID: jobID,
          sourceRelativePath: sourceRelativePath,
          sourceDuration: duration,
          configuration: configuration
        )
      }
    )
  }

  func availableAlternativeProvider(sessionID: UUID) async throws -> ProviderID? {
    guard let session = try await repository.session(id: sessionID) else {
      throw VoiceNoteWorkflowError.sessionNotFound
    }
    let settings = try await settingsRepository.load()
    let currentProviderID =
      try await checkpointConfiguration(
        session: session
      )?.providerID ?? settings.transcriptionProviderID

    switch currentProviderID {
    case .groq:
      guard let appleSpeechCapability else { return nil }
      let capability = await appleSpeechCapability.providerCapability(
        for: TranscriptionCapabilityRequest(
          duration: session.duration,
          languageCode: settings.recognitionLanguageCode
        )
      )
      guard case .available = capability else { return nil }
      return .appleSpeech
    case .appleSpeech:
      guard
        !settings.localOnly,
        settings.hasAcknowledgedGroqCloudProcessing
      else {
        return nil
      }
      return .groq
    default:
      return nil
    }
  }

  func retry(sessionID: UUID, using providerID: ProviderID) async throws {
    guard activeTasks[sessionID] == nil else {
      throw VoiceNoteWorkflowError.operationAlreadyRunning
    }
    guard let session = try await repository.session(id: sessionID) else {
      throw VoiceNoteWorkflowError.sessionNotFound
    }
    let settings = try await settingsRepository.load()
    let expectedAlternative = try await availableAlternativeProvider(
      sessionID: sessionID
    )
    guard expectedAlternative == providerID else {
      throw VoiceNoteWorkflowError.unsupportedProvider
    }
    let manifest = try await fileStore.manifest(sessionID: sessionID)
    guard
      let source = manifest.assets.first(where: {
        $0.kind == .importedOriginal || $0.kind == .archive
      })
    else {
      throw VoiceNotePipelineError.sourceAssetNotFound
    }

    let jobID = UUID()
    let createdAt = now()
    _ = try await repository.createJob(
      NewTranscriptionJob(
        id: jobID,
        sessionID: sessionID,
        createdAt: createdAt
      )
    )
    _ = try await repository.updateSession(
      id: sessionID,
      status: .preprocessing,
      duration: session.duration,
      currentJobID: jobID,
      updatedAt: createdAt
    )
    let configuration = TranscriptionConfiguration(
      providerID: providerID,
      modelID: settings.transcriptionModelID,
      languageCode: settings.recognitionLanguageCode,
      prompt: try await vocabularyProcessor?.promptFragment(
        profileID: settings.activeProfileID
      )
    )
    startTask(
      sessionID: sessionID,
      operation: { [pipeline] in
        try await pipeline.process(
          sessionID: sessionID,
          jobID: jobID,
          sourceRelativePath: source.relativePath,
          sourceDuration: session.duration,
          configuration: configuration
        )
      }
    )
  }

  func cancel(sessionID: UUID) async {
    guard let task = activeTasks[sessionID] else { return }
    task.cancel()
    await task.value
    activeTasks[sessionID] = nil
  }

  func delete(sessionID: UUID) async throws {
    if let task = activeTasks[sessionID] {
      task.cancel()
      await task.value
      activeTasks[sessionID] = nil
    }
    guard let session = try await repository.session(id: sessionID) else {
      return
    }
    _ = try await repository.updateSession(
      id: sessionID,
      status: .pendingDeletion,
      duration: session.duration,
      currentJobID: session.currentJobID,
      updatedAt: now()
    )
    if let journal = try await fileStore.recordingJournal(),
      journal.sessionID == sessionID
    {
      try await fileStore.clearRecordingJournal(sessionID: sessionID)
    }
    try await fileStore.removeSession(sessionID: sessionID)
    try await repository.deleteSessionMetadata(id: sessionID)
  }

  private func transcriptionConfiguration() async throws
    -> TranscriptionConfiguration
  {
    let settings = try await settingsRepository.load()
    guard
      settings.transcriptionProviderID == .groq
        || settings.transcriptionProviderID == .appleSpeech
    else {
      throw VoiceNoteWorkflowError.unsupportedProvider
    }
    guard
      !settings.localOnly
        || settings.transcriptionProviderID == .appleSpeech
    else {
      throw VoiceNoteWorkflowError.unsupportedProvider
    }
    guard
      settings.transcriptionProviderID != .groq
        || settings.hasAcknowledgedGroqCloudProcessing
    else {
      throw VoiceNoteWorkflowError.cloudProcessingConsentRequired
    }
    return TranscriptionConfiguration(
      providerID: settings.transcriptionProviderID,
      modelID: settings.transcriptionModelID,
      languageCode: settings.recognitionLanguageCode,
      prompt: try await vocabularyProcessor?.promptFragment(
        profileID: settings.activeProfileID
      )
    )
  }

  private func checkpointConfiguration(
    session: RecordingSessionDTO
  ) async throws -> TranscriptionConfiguration? {
    guard let jobID = session.currentJobID,
      let job = try await repository.job(id: jobID),
      let checkpointRelativePath = job.checkpointRelativePath
    else {
      return nil
    }
    let manifest = try await fileStore.manifest(sessionID: session.id)
    guard
      let asset = manifest.assets.first(where: {
        $0.relativePath == checkpointRelativePath && $0.kind == .checkpoint
      })
    else {
      return nil
    }
    let checkpoint = try await fileStore.readJSON(
      TranscriptionCheckpoint.self,
      sessionID: session.id,
      relativePath: checkpointRelativePath,
      expectedSHA256: asset.sha256
    )
    return checkpoint.transcriptionConfiguration
  }

  private func startTask(
    sessionID: UUID,
    operation: @escaping @Sendable () async throws -> Void
  ) {
    let task = Task {
      do {
        try await operation()
      } catch {
        // The pipeline persists a metadata-only cancelled or retry-required state.
      }
      taskFinished(sessionID: sessionID)
    }
    activeTasks[sessionID] = task
  }

  private func taskFinished(sessionID: UUID) {
    activeTasks[sessionID] = nil
  }

  private static func resolvedTitle(_ title: String?, sourceURL: URL) -> String {
    let explicit = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !explicit.isEmpty {
      return explicit
    }
    let fileName = sourceURL.deletingPathExtension().lastPathComponent
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return fileName.isEmpty ? String(localized: "Voice Note") : fileName
  }
}

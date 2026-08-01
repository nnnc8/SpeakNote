import Foundation

enum VoiceNotePipelineError: Error, Equatable, Sendable {
  case sessionNotFound
  case jobNotFound
  case jobDoesNotBelongToSession
  case sourceAssetNotFound
  case emptyAudio
  case invalidCheckpoint
  case incompleteCheckpoint
  case missingFrozenConfiguration
}

protocol RawTranscriptRendering: Sendable {
  func render(
    session: RecordingSessionDTO,
    transcript: Transcript
  ) throws -> String
}

protocol VoiceNoteTranscriptionPipelining: Actor {
  func process(
    sessionID: UUID,
    jobID: UUID,
    sourceRelativePath: String,
    sourceDuration: TimeInterval,
    configuration: TranscriptionConfiguration
  ) async throws

  func resume(
    sessionID: UUID,
    configuration: TranscriptionConfiguration
  ) async throws
}

actor VoiceNoteTranscriptionPipeline: VoiceNoteTranscriptionPipelining {
  typealias ChunkerFactory = @Sendable (URL) -> any AudioChunking

  private let repository: any VoiceNoteSessionStoring
  private let fileStore: SessionFileStore
  private let transcriptionEngine: any TranscriptionEngine
  private let markdownRenderer: any RawTranscriptRendering
  private let chunkerFactory: ChunkerFactory
  private let now: @Sendable () -> Date

  init(
    repository: any VoiceNoteSessionStoring,
    fileStore: SessionFileStore,
    transcriptionEngine: any TranscriptionEngine,
    markdownRenderer: any RawTranscriptRendering,
    chunkerFactory: @escaping ChunkerFactory = {
      TimeBasedAudioChunker(destinationDirectory: $0)
    },
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.repository = repository
    self.fileStore = fileStore
    self.transcriptionEngine = transcriptionEngine
    self.markdownRenderer = markdownRenderer
    self.chunkerFactory = chunkerFactory
    self.now = now
  }

  func process(
    sessionID: UUID,
    jobID: UUID,
    sourceRelativePath: String,
    sourceDuration: TimeInterval,
    configuration: TranscriptionConfiguration
  ) async throws {
    guard let session = try await repository.session(id: sessionID) else {
      throw VoiceNotePipelineError.sessionNotFound
    }
    guard let job = try await repository.job(id: jobID) else {
      throw VoiceNotePipelineError.jobNotFound
    }
    guard job.sessionID == sessionID else {
      throw VoiceNotePipelineError.jobDoesNotBelongToSession
    }
    guard sourceDuration.isFinite, sourceDuration >= 0 else {
      throw VoiceNotePipelineError.invalidCheckpoint
    }
    if try await reconcileCompletedSession(session: session, job: job) {
      return
    }

    do {
      try await fileStore.updateState(sessionID: sessionID, state: .processing)
      _ = try await repository.updateJob(
        id: jobID,
        stage: .preprocessing,
        completedChunks: job.completedChunks,
        totalChunks: job.totalChunks,
        checkpointRelativePath: job.checkpointRelativePath,
        errorCategory: nil,
        updatedAt: now()
      )
      _ = try await repository.updateSession(
        id: sessionID,
        status: .preprocessing,
        duration: sourceDuration,
        currentJobID: jobID,
        updatedAt: now()
      )
      var checkpoint = try await prepareCheckpoint(
        sessionID: sessionID,
        jobID: jobID,
        sourceRelativePath: sourceRelativePath,
        sourceDuration: sourceDuration,
        configuration: configuration
      )
      checkpoint = try await transcribeRemainingChunks(checkpoint)
      try Task.checkCancellation()
      try await mergeAndExport(checkpoint)
    } catch is CancellationError {
      await markCancelled(sessionID: sessionID, jobID: jobID)
      throw CancellationError()
    } catch {
      await markFailure(error, sessionID: sessionID, jobID: jobID)
      throw error
    }
  }

  func resume(
    sessionID: UUID,
    configuration: TranscriptionConfiguration
  ) async throws {
    guard let session = try await repository.session(id: sessionID) else {
      throw VoiceNotePipelineError.sessionNotFound
    }
    guard let jobID = session.currentJobID,
      let job = try await repository.job(id: jobID)
    else {
      throw VoiceNotePipelineError.jobNotFound
    }
    if try await reconcileCompletedSession(session: session, job: job) {
      return
    }

    let sourceRelativePath: String
    let sourceDuration: TimeInterval
    let resumedConfiguration: TranscriptionConfiguration
    do {
      let checkpointPath = Self.checkpointPath(jobID: jobID)
      if let checkpointAsset = try await asset(
        sessionID: sessionID,
        relativePath: checkpointPath
      ) {
        let checkpoint = try await fileStore.readJSON(
          TranscriptionCheckpoint.self,
          sessionID: sessionID,
          relativePath: checkpointPath,
          expectedSHA256: checkpointAsset.sha256
        )
        try validate(checkpoint, sessionID: sessionID, jobID: jobID)
        sourceRelativePath = checkpoint.sourceRelativePath
        sourceDuration = checkpoint.sourceDuration
        if let frozen = checkpoint.transcriptionConfiguration {
          resumedConfiguration = frozen
        } else if checkpoint.completedChunks.isEmpty {
          // A v1 checkpoint with no provider output can be migrated safely.
          resumedConfiguration = configuration
        } else {
          throw VoiceNotePipelineError.missingFrozenConfiguration
        }
      } else {
        let manifest = try await fileStore.manifest(sessionID: sessionID)
        guard
          let source = manifest.assets.first(where: {
            $0.kind == .importedOriginal || $0.kind == .archive
              || $0.kind == .captureSegment
          })
        else {
          throw VoiceNotePipelineError.sourceAssetNotFound
        }
        sourceRelativePath = source.relativePath
        sourceDuration = session.duration
        resumedConfiguration = configuration
      }
    } catch {
      await markFailure(error, sessionID: sessionID, jobID: jobID)
      throw error
    }

    try await process(
      sessionID: sessionID,
      jobID: jobID,
      sourceRelativePath: sourceRelativePath,
      sourceDuration: sourceDuration,
      configuration: resumedConfiguration
    )
  }

  private func prepareCheckpoint(
    sessionID: UUID,
    jobID: UUID,
    sourceRelativePath: String,
    sourceDuration: TimeInterval,
    configuration: TranscriptionConfiguration
  ) async throws -> TranscriptionCheckpoint {
    let checkpointPath = Self.checkpointPath(jobID: jobID)
    let existing: TranscriptionCheckpoint?
    if let asset = try await asset(
      sessionID: sessionID,
      relativePath: checkpointPath
    ) {
      existing = try await fileStore.readJSON(
        TranscriptionCheckpoint.self,
        sessionID: sessionID,
        relativePath: checkpointPath,
        expectedSHA256: asset.sha256
      )
      if let existing {
        try validate(existing, sessionID: sessionID, jobID: jobID)
        guard existing.sourceRelativePath == sourceRelativePath,
          existing.sourceDuration == sourceDuration
        else {
          throw VoiceNotePipelineError.invalidCheckpoint
        }
        if let frozen = existing.transcriptionConfiguration {
          guard frozen == configuration else {
            throw VoiceNotePipelineError.invalidCheckpoint
          }
        } else if !existing.completedChunks.isEmpty {
          throw VoiceNotePipelineError.missingFrozenConfiguration
        }
        if existing.chunks.count == existing.totalChunks {
          var migrated = existing
          if migrated.transcriptionConfiguration == nil {
            migrated.transcriptionConfiguration = configuration
            migrated.updatedAt = now()
            _ = try await fileStore.replaceJSON(
              migrated,
              sessionID: sessionID,
              relativePath: checkpointPath,
              kind: .checkpoint,
              updatedAt: migrated.updatedAt
            )
          }
          return migrated
        }
      }
    } else {
      existing = nil
    }

    _ = try await repository.updateJob(
      id: jobID,
      stage: .chunking,
      completedChunks: existing?.completedChunks.count ?? 0,
      totalChunks: existing?.totalChunks ?? 0,
      checkpointRelativePath: checkpointPath,
      errorCategory: nil,
      updatedAt: now()
    )
    let sourceURL = try await fileStore.fileURL(
      sessionID: sessionID,
      relativePath: sourceRelativePath
    )
    let temporaryDirectory = try await fileStore.temporaryJobDirectory(jobID: jobID)
    let generated: [AudioChunk]
    do {
      generated = try await chunkerFactory(temporaryDirectory).chunks(from: sourceURL)
    } catch {
      await fileStore.removeTemporaryJobDirectory(jobID: jobID)
      throw error
    }
    guard !generated.isEmpty else {
      await fileStore.removeTemporaryJobDirectory(jobID: jobID)
      throw VoiceNotePipelineError.emptyAudio
    }

    do {
      let ordered = generated.sorted {
        ($0.index, $0.startTime, $0.url.path)
          < ($1.index, $1.startTime, $1.url.path)
      }
      guard ordered.map(\.index) == Array(0..<ordered.count) else {
        throw VoiceNotePipelineError.invalidCheckpoint
      }
      if let existing {
        guard existing.totalChunks == ordered.count else {
          throw VoiceNotePipelineError.invalidCheckpoint
        }
      }

      var checkpoint =
        existing
        ?? TranscriptionCheckpoint(
          jobID: jobID,
          sessionID: sessionID,
          totalChunks: ordered.count,
          sourceRelativePath: sourceRelativePath,
          sourceDuration: sourceDuration,
          transcriptionConfiguration: configuration,
          updatedAt: now()
        )
      if checkpoint.transcriptionConfiguration == nil {
        checkpoint.transcriptionConfiguration = configuration
      }
      if existing == nil {
        _ = try await fileStore.replaceJSON(
          checkpoint,
          sessionID: sessionID,
          relativePath: checkpointPath,
          kind: .checkpoint,
          updatedAt: checkpoint.updatedAt
        )
      }
      _ = try await repository.updateJob(
        id: jobID,
        stage: .chunking,
        completedChunks: checkpoint.completedChunks.count,
        totalChunks: ordered.count,
        checkpointRelativePath: checkpointPath,
        errorCategory: nil,
        updatedAt: now()
      )

      for chunk in ordered {
        try Task.checkCancellation()
        if let prior = checkpoint.chunks.first(where: { $0.index == chunk.index }) {
          guard Self.matches(prior, chunk) else {
            throw VoiceNotePipelineError.invalidCheckpoint
          }
          continue
        }

        let relativePath = Self.audioChunkPath(jobID: jobID, index: chunk.index)
        let storedAsset: SessionManifest.Asset
        if let existingAsset = try await asset(
          sessionID: sessionID,
          relativePath: relativePath
        ) {
          guard existingAsset.sha256 == chunk.sha256,
            existingAsset.byteCount == chunk.byteCount
          else {
            throw VoiceNotePipelineError.invalidCheckpoint
          }
          storedAsset = existingAsset
        } else {
          storedAsset = try await fileStore.copyAsset(
            from: chunk.url,
            sessionID: sessionID,
            relativePath: relativePath,
            kind: .audioChunk,
            createdAt: now()
          )
          guard storedAsset.sha256 == chunk.sha256,
            storedAsset.byteCount == chunk.byteCount
          else {
            throw VoiceNotePipelineError.invalidCheckpoint
          }
        }

        checkpoint.chunks.append(
          TranscriptionCheckpoint.Chunk(
            index: chunk.index,
            audioRelativePath: relativePath,
            startTime: chunk.startTime,
            endTime: chunk.endTime,
            byteCount: storedAsset.byteCount,
            sha256: storedAsset.sha256
          )
        )
        checkpoint.chunks.sort { $0.index < $1.index }
        checkpoint.updatedAt = now()
        _ = try await fileStore.replaceJSON(
          checkpoint,
          sessionID: sessionID,
          relativePath: checkpointPath,
          kind: .checkpoint,
          updatedAt: checkpoint.updatedAt
        )
      }
      guard checkpoint.chunks.count == checkpoint.totalChunks else {
        throw VoiceNotePipelineError.incompleteCheckpoint
      }
      await fileStore.removeTemporaryJobDirectory(jobID: jobID)
      return checkpoint
    } catch {
      await fileStore.removeTemporaryJobDirectory(jobID: jobID)
      throw error
    }
  }

  private func transcribeRemainingChunks(
    _ initial: TranscriptionCheckpoint
  ) async throws -> TranscriptionCheckpoint {
    var checkpoint = initial
    guard let configuration = checkpoint.transcriptionConfiguration else {
      throw VoiceNotePipelineError.missingFrozenConfiguration
    }
    let checkpointPath = Self.checkpointPath(jobID: checkpoint.jobID)
    _ = try await repository.updateJob(
      id: checkpoint.jobID,
      stage: .transcribing,
      completedChunks: checkpoint.completedChunks.count,
      totalChunks: checkpoint.totalChunks,
      checkpointRelativePath: checkpointPath,
      errorCategory: nil,
      updatedAt: now()
    )
    _ = try await repository.updateSession(
      id: checkpoint.sessionID,
      status: .transcribing,
      duration: checkpoint.sourceDuration,
      currentJobID: checkpoint.jobID,
      updatedAt: now()
    )

    for chunk in checkpoint.chunks.sorted(by: { $0.index < $1.index }) {
      try Task.checkCancellation()
      if let completed = checkpoint.completedChunks.first(where: {
        $0.index == chunk.index
      }) {
        _ = try await fileStore.readJSON(
          Transcript.self,
          sessionID: checkpoint.sessionID,
          relativePath: completed.responseRelativePath,
          expectedSHA256: completed.responseSHA256
        )
        continue
      }

      let responsePath = Self.responsePath(
        jobID: checkpoint.jobID,
        index: chunk.index
      )
      let responseAsset: SessionManifest.Asset
      if let existing = try await asset(
        sessionID: checkpoint.sessionID,
        relativePath: responsePath
      ) {
        _ = try await fileStore.readJSON(
          Transcript.self,
          sessionID: checkpoint.sessionID,
          relativePath: responsePath,
          expectedSHA256: existing.sha256
        )
        responseAsset = existing
      } else {
        let chunkURL = try await fileStore.fileURL(
          sessionID: checkpoint.sessionID,
          relativePath: chunk.audioRelativePath
        )
        let transcript = try await transcriptionEngine.transcribe(
          audioURL: chunkURL,
          configuration: configuration
        )
        try Task.checkCancellation()
        responseAsset = try await fileStore.writeJSON(
          transcript,
          sessionID: checkpoint.sessionID,
          relativePath: responsePath,
          kind: .rawChunkResponse,
          createdAt: now()
        )
      }

      checkpoint.completedChunks.append(
        TranscriptionCheckpoint.CompletedChunk(
          index: chunk.index,
          responseRelativePath: responsePath,
          responseSHA256: responseAsset.sha256
        )
      )
      checkpoint.completedChunks.sort { $0.index < $1.index }
      checkpoint.updatedAt = now()
      _ = try await fileStore.replaceJSON(
        checkpoint,
        sessionID: checkpoint.sessionID,
        relativePath: checkpointPath,
        kind: .checkpoint,
        updatedAt: checkpoint.updatedAt
      )
      _ = try await repository.updateJob(
        id: checkpoint.jobID,
        stage: .transcribing,
        completedChunks: checkpoint.completedChunks.count,
        totalChunks: checkpoint.totalChunks,
        checkpointRelativePath: checkpointPath,
        errorCategory: nil,
        updatedAt: now()
      )
    }
    return checkpoint
  }

  private func mergeAndExport(
    _ checkpoint: TranscriptionCheckpoint
  ) async throws {
    guard checkpoint.completedChunks.count == checkpoint.totalChunks else {
      throw VoiceNotePipelineError.incompleteCheckpoint
    }
    let checkpointPath = Self.checkpointPath(jobID: checkpoint.jobID)
    _ = try await repository.updateJob(
      id: checkpoint.jobID,
      stage: .merging,
      completedChunks: checkpoint.completedChunks.count,
      totalChunks: checkpoint.totalChunks,
      checkpointRelativePath: checkpointPath,
      errorCategory: nil,
      updatedAt: now()
    )
    _ = try await repository.updateSession(
      id: checkpoint.sessionID,
      status: .merging,
      duration: checkpoint.sourceDuration,
      currentJobID: checkpoint.jobID,
      updatedAt: now()
    )

    var inputs: [ChunkTranscript] = []
    for chunk in checkpoint.chunks.sorted(by: { $0.index < $1.index }) {
      try Task.checkCancellation()
      guard
        let completed = checkpoint.completedChunks.first(where: {
          $0.index == chunk.index
        })
      else {
        throw VoiceNotePipelineError.incompleteCheckpoint
      }
      let transcript = try await fileStore.readJSON(
        Transcript.self,
        sessionID: checkpoint.sessionID,
        relativePath: completed.responseRelativePath,
        expectedSHA256: completed.responseSHA256
      )
      let audioURL = try await fileStore.fileURL(
        sessionID: checkpoint.sessionID,
        relativePath: chunk.audioRelativePath
      )
      inputs.append(
        ChunkTranscript(
          chunk: AudioChunk(
            index: chunk.index,
            url: audioURL,
            startTime: chunk.startTime,
            endTime: chunk.endTime,
            byteCount: chunk.byteCount,
            sha256: chunk.sha256
          ),
          transcript: transcript
        )
      )
    }

    try Task.checkCancellation()
    let rawJSONPath = "transcripts/raw-v1.json"
    let transcript: Transcript
    if let existing = try await asset(
      sessionID: checkpoint.sessionID,
      relativePath: rawJSONPath
    ) {
      transcript = try await fileStore.readJSON(
        Transcript.self,
        sessionID: checkpoint.sessionID,
        relativePath: rawJSONPath,
        expectedSHA256: existing.sha256
      )
    } else {
      transcript = TranscriptMerger().merge(
        inputs,
        sourceDuration: checkpoint.sourceDuration
      )
      _ = try await fileStore.writeJSON(
        transcript,
        sessionID: checkpoint.sessionID,
        relativePath: rawJSONPath,
        kind: .rawTranscriptJSON,
        createdAt: now()
      )
    }

    try Task.checkCancellation()
    _ = try await repository.updateJob(
      id: checkpoint.jobID,
      stage: .exporting,
      completedChunks: checkpoint.completedChunks.count,
      totalChunks: checkpoint.totalChunks,
      checkpointRelativePath: checkpointPath,
      errorCategory: nil,
      updatedAt: now()
    )
    guard let session = try await repository.session(id: checkpoint.sessionID) else {
      throw VoiceNotePipelineError.sessionNotFound
    }
    try Task.checkCancellation()
    let markdownPath = "transcripts/raw-v1.md"
    if let existing = try await asset(
      sessionID: checkpoint.sessionID,
      relativePath: markdownPath
    ) {
      _ = try await fileStore.readData(
        sessionID: checkpoint.sessionID,
        relativePath: markdownPath,
        expectedSHA256: existing.sha256
      )
    } else {
      let markdown = try markdownRenderer.render(
        session: session,
        transcript: transcript
      )
      try Task.checkCancellation()
      _ = try await fileStore.write(
        Data(markdown.utf8),
        sessionID: checkpoint.sessionID,
        relativePath: markdownPath,
        kind: .rawTranscriptMarkdown,
        createdAt: now()
      )
    }

    try Task.checkCancellation()
    try await fileStore.updateState(
      sessionID: checkpoint.sessionID,
      state: .completed,
      at: now()
    )
    _ = try await repository.updateJob(
      id: checkpoint.jobID,
      stage: .completed,
      completedChunks: checkpoint.completedChunks.count,
      totalChunks: checkpoint.totalChunks,
      checkpointRelativePath: checkpointPath,
      errorCategory: nil,
      updatedAt: now()
    )
    _ = try await repository.updateSession(
      id: checkpoint.sessionID,
      status: .completed,
      duration: checkpoint.sourceDuration,
      currentJobID: checkpoint.jobID,
      updatedAt: now()
    )
  }

  private func reconcileCompletedSession(
    session: RecordingSessionDTO,
    job: TranscriptionJobDTO
  ) async throws -> Bool {
    guard job.stage == .completed, session.status == .completed else {
      return false
    }

    do {
      let manifest = try await fileStore.manifest(sessionID: session.id)
      guard
        let rawJSON = manifest.assets.first(where: {
          $0.relativePath == "transcripts/raw-v1.json"
        }),
        let rawMarkdown = manifest.assets.first(where: {
          $0.relativePath == "transcripts/raw-v1.md"
        })
      else {
        throw VoiceNotePipelineError.incompleteCheckpoint
      }
      _ = try await fileStore.readJSON(
        Transcript.self,
        sessionID: session.id,
        relativePath: rawJSON.relativePath,
        expectedSHA256: rawJSON.sha256
      )
      _ = try await fileStore.readData(
        sessionID: session.id,
        relativePath: rawMarkdown.relativePath,
        expectedSHA256: rawMarkdown.sha256
      )
      try await fileStore.updateState(
        sessionID: session.id,
        state: .completed,
        at: now()
      )
      return true
    } catch {
      await markFailure(error, sessionID: session.id, jobID: job.id)
      throw error
    }
  }

  private func validate(
    _ checkpoint: TranscriptionCheckpoint,
    sessionID: UUID,
    jobID: UUID
  ) throws {
    guard (1...TranscriptionCheckpoint.currentVersion).contains(checkpoint.version),
      checkpoint.sessionID == sessionID,
      checkpoint.jobID == jobID,
      checkpoint.totalChunks > 0,
      checkpoint.sourceDuration.isFinite,
      checkpoint.sourceDuration >= 0,
      !checkpoint.sourceRelativePath.isEmpty,
      checkpoint.chunks.count <= checkpoint.totalChunks,
      checkpoint.completedChunks.count <= checkpoint.totalChunks,
      Set(checkpoint.chunks.map(\.index)).count == checkpoint.chunks.count,
      Set(checkpoint.completedChunks.map(\.index)).count
        == checkpoint.completedChunks.count,
      checkpoint.chunks.allSatisfy({
        $0.index >= 0 && $0.index < checkpoint.totalChunks
          && $0.startTime.isFinite && $0.endTime.isFinite
          && $0.startTime >= 0 && $0.endTime >= $0.startTime
          && $0.byteCount > 0 && !$0.sha256.isEmpty
          && !$0.audioRelativePath.isEmpty
      }),
      checkpoint.completedChunks.allSatisfy({
        $0.index >= 0 && $0.index < checkpoint.totalChunks
          && !$0.responseRelativePath.isEmpty && !$0.responseSHA256.isEmpty
      })
    else {
      throw VoiceNotePipelineError.invalidCheckpoint
    }
  }

  private func asset(
    sessionID: UUID,
    relativePath: String
  ) async throws -> SessionManifest.Asset? {
    try await fileStore.manifest(sessionID: sessionID).assets.first {
      $0.relativePath == relativePath
    }
  }

  private func markCancelled(sessionID: UUID, jobID: UUID) async {
    guard let session = try? await repository.session(id: sessionID),
      let job = try? await repository.job(id: jobID)
    else {
      return
    }
    _ = try? await repository.updateJob(
      id: jobID,
      stage: .cancelled,
      completedChunks: job.completedChunks,
      totalChunks: job.totalChunks,
      checkpointRelativePath: job.checkpointRelativePath,
      errorCategory: nil,
      updatedAt: now()
    )
    _ = try? await repository.updateSession(
      id: sessionID,
      status: .cancelled,
      duration: session.duration,
      currentJobID: jobID,
      updatedAt: now()
    )
    try? await fileStore.updateState(sessionID: sessionID, state: .ready, at: now())
  }

  private func markFailure(_ error: Error, sessionID: UUID, jobID: UUID) async {
    let category = Self.errorCategory(error)
    if let job = try? await repository.job(id: jobID) {
      _ = try? await repository.updateJob(
        id: jobID,
        stage: .retryRequired,
        completedChunks: job.completedChunks,
        totalChunks: job.totalChunks,
        checkpointRelativePath: job.checkpointRelativePath,
        errorCategory: category,
        updatedAt: now()
      )
    }
    if Self.isIntegrityFailure(error) {
      _ = try? await repository.markSessionNeedsRepair(
        id: sessionID,
        updatedAt: now()
      )
      try? await fileStore.updateState(
        sessionID: sessionID,
        state: .needsRepair,
        at: now()
      )
    } else if let session = try? await repository.session(id: sessionID) {
      _ = try? await repository.updateSession(
        id: sessionID,
        status: .retryRequired,
        duration: session.duration,
        currentJobID: jobID,
        updatedAt: now()
      )
      try? await fileStore.updateState(
        sessionID: sessionID,
        state: .retryRequired,
        at: now()
      )
    }
  }

  private static func matches(
    _ stored: TranscriptionCheckpoint.Chunk,
    _ generated: AudioChunk
  ) -> Bool {
    stored.index == generated.index
      && stored.sha256 == generated.sha256
      && stored.byteCount == generated.byteCount
      && abs(stored.startTime - generated.startTime) < 0.001
      && abs(stored.endTime - generated.endTime) < 0.001
  }

  private static func isIntegrityFailure(_ error: Error) -> Bool {
    if error is DecodingError {
      return true
    }
    if let pipeline = error as? VoiceNotePipelineError {
      switch pipeline {
      case .sourceAssetNotFound, .invalidCheckpoint, .incompleteCheckpoint:
        return true
      default:
        return false
      }
    }
    if let store = error as? SessionFileStoreError {
      switch store {
      case .sessionNotFound, .unsupportedManifestVersion, .assetAlreadyExists,
        .checksumMismatch, .invalidRelativePath:
        return true
      default:
        return false
      }
    }
    return false
  }

  private static func errorCategory(_ error: Error) -> String {
    if let groq = error as? GroqAPIError, groq == .ambiguousCompletion {
      return "ambiguousCompletionConfirmationRequired"
    }
    if isIntegrityFailure(error) {
      return "sessionIntegrity"
    }
    if error is AudioChunkerError {
      return "audioPreprocessing"
    }
    if error is LiveTranscriptionEngineError || error is GroqAPIError {
      return "transcriptionProvider"
    }
    return "voiceNoteProcessing"
  }

  private static func checkpointPath(jobID: UUID) -> String {
    "jobs/\(jobID.uuidString)/checkpoint.json"
  }

  private static func audioChunkPath(jobID: UUID, index: Int) -> String {
    "jobs/\(jobID.uuidString)/chunks/\(String(format: "%04d", index)).wav"
  }

  private static func responsePath(jobID: UUID, index: Int) -> String {
    "jobs/\(jobID.uuidString)/responses/\(String(format: "%04d", index)).json"
  }
}

import CryptoKit
import Foundation

enum VoiceNoteStructuredProcessingError: Error, Equatable, Sendable {
  case cloudProcessingConsentRequired
  case unsupportedProvider
  case invalidModel
  case rawTranscriptNotFound
  case operationAlreadyRunning
}

protocol VoiceNoteStructuredProcessingRunning: Actor {
  func process(
    sessionID: UUID,
    noteType: NoteType
  ) async throws -> VoiceNoteStructuredRun
  func runs(sessionID: UUID) async throws -> [ProcessingRunDTO]
  func read(
    sessionID: UUID,
    runID: UUID
  ) async throws -> VoiceNoteStructuredRun?
}

struct VoiceNoteStructuredProcessingConfiguration: Codable, Equatable, Sendable {
  static let currentVersion = 2

  let version: Int
  let noteType: NoteType
  let providerID: String
  let modelID: String
  let profileID: UUID?
  let vocabularyConfigurationHash: String?

  init(
    version: Int = Self.currentVersion,
    noteType: NoteType,
    providerID: String,
    modelID: String,
    profileID: UUID? = nil,
    vocabularyConfigurationHash: String? = nil
  ) {
    self.version = version
    self.noteType = noteType
    self.providerID = providerID
    self.modelID = modelID
    self.profileID = profileID
    self.vocabularyConfigurationHash = vocabularyConfigurationHash
  }

  func hash() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(self)
    return SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }
}

actor VoiceNoteStructuredProcessingWorkflow:
  VoiceNoteStructuredProcessingRunning
{
  private let settingsRepository: any SettingsStoring
  private let fileStore: SessionFileStore
  private let processor: M5StructuredNoteProcessor
  private let runStore: any VoiceNoteStructuredRunPersisting
  private let vocabularyProcessor: (any VocabularyProcessing)?
  private let renderer: StructuredNoteMarkdownRenderer
  private let now: @Sendable () -> Date
  private let makeID: @Sendable () -> UUID
  private var activeSessionIDs: Set<UUID> = []

  init(
    settingsRepository: any SettingsStoring,
    fileStore: SessionFileStore,
    processor: M5StructuredNoteProcessor,
    runStore: any VoiceNoteStructuredRunPersisting,
    vocabularyProcessor: (any VocabularyProcessing)? = nil,
    renderer: StructuredNoteMarkdownRenderer = StructuredNoteMarkdownRenderer(),
    now: @escaping @Sendable () -> Date = Date.init,
    makeID: @escaping @Sendable () -> UUID = UUID.init
  ) {
    self.settingsRepository = settingsRepository
    self.fileStore = fileStore
    self.processor = processor
    self.runStore = runStore
    self.vocabularyProcessor = vocabularyProcessor
    self.renderer = renderer
    self.now = now
    self.makeID = makeID
  }

  func process(
    sessionID: UUID,
    noteType: NoteType
  ) async throws -> VoiceNoteStructuredRun {
    guard activeSessionIDs.insert(sessionID).inserted else {
      throw VoiceNoteStructuredProcessingError.operationAlreadyRunning
    }
    defer { activeSessionIDs.remove(sessionID) }

    let settings = try await settingsRepository.load()
    guard settings.textProcessingProviderID == .groq else {
      throw VoiceNoteStructuredProcessingError.unsupportedProvider
    }
    guard settings.hasAcknowledgedGroqCloudProcessing else {
      throw VoiceNoteStructuredProcessingError.cloudProcessingConsentRequired
    }
    let modelID = settings.structuredTextModelID
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !modelID.isEmpty else {
      throw VoiceNoteStructuredProcessingError.invalidModel
    }

    let manifest = try await fileStore.manifest(sessionID: sessionID)
    guard
      let rawAsset = manifest.assets.first(where: {
        $0.kind == .rawTranscriptJSON
          && $0.relativePath == "transcripts/raw-v1.json"
      })
    else {
      throw VoiceNoteStructuredProcessingError.rawTranscriptNotFound
    }
    let rawTranscript = try await fileStore.readJSON(
      Transcript.self,
      sessionID: sessionID,
      relativePath: rawAsset.relativePath,
      expectedSHA256: rawAsset.sha256
    )
    let vocabularyResult: VocabularyTranscriptResult
    if let vocabularyProcessor {
      vocabularyResult = try await vocabularyProcessor.apply(
        to: rawTranscript,
        profileID: settings.activeProfileID,
        recordHistory: settings.dictationHistoryEnabled
      )
    } else {
      vocabularyResult = VocabularyTranscriptResult(
        transcript: rawTranscript,
        audits: [],
        configurationHash: nil
      )
    }
    let configuration = VoiceNoteStructuredProcessingConfiguration(
      noteType: noteType,
      providerID: settings.textProcessingProviderID.rawValue,
      modelID: modelID,
      profileID: settings.activeProfileID,
      vocabularyConfigurationHash: vocabularyResult.configurationHash
    )
    let metadata = VoiceNoteStructuredRunMetadata(
      noteType: noteType,
      providerID: configuration.providerID,
      modelID: modelID,
      configurationHash: try configuration.hash()
    )
    let runID = makeID()
    let createdAt = now()

    do {
      try Task.checkCancellation()
      let sourceDuration = try await runStore.sourceDuration(
        sessionID: sessionID
      )
      let reduction = try await processor.process(
        transcript: vocabularyResult.transcript,
        noteType: noteType,
        sourceDuration: sourceDuration,
        modelID: modelID
      )
      try Task.checkCancellation()
      let markdown = renderer.render(reduction.document)
      return try await runStore.append(
        NewVoiceNoteStructuredRun(
          id: runID,
          sessionID: sessionID,
          createdAt: createdAt,
          metadata: metadata,
          document: reduction.document,
          markdown: markdown,
          partialFailures: reduction.failures
        )
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      _ = try? await runStore.appendFailure(
        sessionID: sessionID,
        runID: runID,
        createdAt: createdAt,
        metadata: metadata,
        errorCategory: Self.errorCategory(for: error)
      )
      throw error
    }
  }

  func runs(sessionID: UUID) async throws -> [ProcessingRunDTO] {
    try await runStore.runs(sessionID: sessionID)
  }

  func read(
    sessionID: UUID,
    runID: UUID
  ) async throws -> VoiceNoteStructuredRun? {
    try await runStore.read(sessionID: sessionID, runID: runID)
  }

  private static func errorCategory(for error: any Error) -> String {
    if error is StructuredNoteValidationError {
      return "structuredValidation"
    }
    if error is LiveTextProcessingEngineError {
      return "providerConfiguration"
    }
    if error is GroqTextProcessingError {
      return "providerRequest"
    }
    return "structuredProcessing"
  }
}

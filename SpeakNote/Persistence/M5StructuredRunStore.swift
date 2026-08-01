import CryptoKit
import Darwin
import Foundation

enum VoiceNoteStructuredRunStoreError: Error, Equatable, Sendable {
  case invalidMetadata
  case invalidErrorCategory
  case noteTypeMismatch(expected: NoteType, actual: NoteType)
  case markdownMismatch
  case incompleteRun(UUID)
  case invalidMarkdownEncoding(UUID)
  case outputMismatch(UUID)
  case rollbackFailed(UUID)
  case sessionNotFound(UUID)
  case invalidTransactionMarker
}

struct VoiceNoteStructuredRunMetadata: Equatable, Sendable {
  let noteType: NoteType
  let providerID: String
  let modelID: String
  let configurationHash: String
}

struct NewVoiceNoteStructuredRun: Equatable, Sendable {
  let id: UUID
  let sessionID: UUID
  let createdAt: Date
  let metadata: VoiceNoteStructuredRunMetadata
  let document: ProcessedDocument
  let markdown: String
  let partialFailures: [StructuredNotePartialFailure]

  init(
    id: UUID = UUID(),
    sessionID: UUID,
    createdAt: Date = Date(),
    metadata: VoiceNoteStructuredRunMetadata,
    document: ProcessedDocument,
    markdown: String,
    partialFailures: [StructuredNotePartialFailure] = []
  ) {
    self.id = id
    self.sessionID = sessionID
    self.createdAt = createdAt
    self.metadata = metadata
    self.document = document
    self.markdown = markdown
    self.partialFailures = partialFailures
  }
}

enum VoiceNoteStructuredRunWarning {
  private static let prefix = "partialStructuredResult|"

  static func errorCategory(
    for failures: [StructuredNotePartialFailure]
  ) -> String? {
    guard !failures.isEmpty else { return nil }
    let details = failures.sorted { $0.groupIndex < $1.groupIndex }.map {
      "\($0.groupIndex)=\(category(for: $0.error))"
    }
    return prefix + details.joined(separator: ",")
  }

  static func message(for errorCategory: String?) -> String? {
    guard let errorCategory, errorCategory.hasPrefix(prefix) else { return nil }
    let details = errorCategory.dropFirst(prefix.count).split(separator: ",")
      .compactMap { entry -> String? in
        let fields = entry.split(separator: "=", maxSplits: 1)
        guard fields.count == 2 else { return nil }
        return String(localized: "group \(fields[0]) (\(fields[1]))")
      }
    guard !details.isEmpty else { return nil }
    return String(
      localized: "Partial result: \(details.joined(separator: ", ")) failed."
    )
  }

  private static func category(
    for error: StructuredNoteValidationError
  ) -> String {
    return switch error {
    case .invalidJSON: "invalidJSON"
    case .providerFailure: "providerFailure"
    case .invalidSourceDuration: "invalidSourceDuration"
    case .noteTypeMismatch: "noteTypeMismatch"
    case .groupIndexMismatch: "groupIndexMismatch"
    case .incompatibleSpecializedFields: "incompatibleSpecializedFields"
    case .emptyField: "emptyField"
    case .missingSourceRange: "missingSourceRange"
    case .invalidSourceRange: "invalidSourceRange"
    case .duplicateSourceRange: "duplicateSourceRange"
    case .outOfRangeSourceRange: "outOfRangeSourceRange"
    case .duplicateGroup: "duplicateGroup"
    case .noUsablePartials: "noUsablePartials"
    }
  }
}

struct VoiceNoteStructuredRun: Equatable, Sendable {
  let run: ProcessingRunDTO
  let document: ProcessedDocument?
  let markdown: String?
}

protocol VoiceNoteStructuredRunPersisting: Actor {
  func append(_ newRun: NewVoiceNoteStructuredRun) async throws
    -> VoiceNoteStructuredRun
  func appendFailure(
    sessionID: UUID,
    runID: UUID,
    createdAt: Date,
    metadata: VoiceNoteStructuredRunMetadata,
    errorCategory: String
  ) async throws -> ProcessingRunDTO
  func runs(sessionID: UUID) async throws -> [ProcessingRunDTO]
  func sourceDuration(sessionID: UUID) async throws -> TimeInterval
  func read(sessionID: UUID, runID: UUID) async throws
    -> VoiceNoteStructuredRun?
}

protocol VoiceNoteProcessingRunStoring: Actor {
  func appendRun(_ run: NewProcessingRun) throws -> ProcessingRunDTO
  func runs(
    ownerKind: ProcessingRunOwnerKind,
    ownerID: UUID
  ) throws -> [ProcessingRunDTO]
  func m5SourceDuration(sessionID: UUID) throws -> TimeInterval?
}

extension VoiceNoteProcessingRunStoring {
  func m5SourceDuration(sessionID: UUID) throws -> TimeInterval? { nil }
}

extension SwiftDataSessionRepository: VoiceNoteProcessingRunStoring {
  func m5SourceDuration(sessionID: UUID) throws -> TimeInterval? {
    try session(id: sessionID)?.duration
  }
}

struct M5StructuredRunArtifacts: Equatable, Sendable {
  let document: ProcessedDocument
  let markdown: String
}

struct M5StructuredRunTransaction: Codable, Equatable, Sendable {
  static let currentVersion = 1

  let version: Int
  let sessionID: UUID
  let runID: UUID
  let createdAt: Date
  let providerID: String
  let modelID: String
  let configurationHash: String
  let errorCategory: String?

  init(
    version: Int = Self.currentVersion,
    sessionID: UUID,
    runID: UUID,
    createdAt: Date,
    providerID: String,
    modelID: String,
    configurationHash: String,
    errorCategory: String?
  ) {
    self.version = version
    self.sessionID = sessionID
    self.runID = runID
    self.createdAt = createdAt
    self.providerID = providerID
    self.modelID = modelID
    self.configurationHash = configurationHash
    self.errorCategory = errorCategory
  }
}

protocol M5StructuredRunReconciling: Actor {
  func reconcileM5StructuredRuns() async throws
}

protocol M5StructuredRunAssetStoring: Actor {
  func commitM5StructuredRun(
    transaction: M5StructuredRunTransaction,
    document: ProcessedDocument,
    markdown: String
  ) throws
  func rollbackM5StructuredRun(sessionID: UUID, runID: UUID) throws
  func completeM5StructuredRun(sessionID: UUID, runID: UUID) throws
  func pendingM5StructuredRunTransactions() throws
    -> [M5StructuredRunTransaction]
  func readM5StructuredRun(sessionID: UUID, runID: UUID) throws
    -> M5StructuredRunArtifacts
}

actor VoiceNoteStructuredRunStore:
  VoiceNoteStructuredRunPersisting,
  M5StructuredRunReconciling
{
  private let fileStore: any M5StructuredRunAssetStoring
  private let history: any VoiceNoteProcessingRunStoring

  init(
    fileStore: any M5StructuredRunAssetStoring,
    history: any VoiceNoteProcessingRunStoring
  ) {
    self.fileStore = fileStore
    self.history = history
  }

  func append(_ newRun: NewVoiceNoteStructuredRun) async throws
    -> VoiceNoteStructuredRun
  {
    try Self.validate(newRun.metadata)
    guard newRun.document.noteType == newRun.metadata.noteType else {
      throw VoiceNoteStructuredRunStoreError.noteTypeMismatch(
        expected: newRun.metadata.noteType,
        actual: newRun.document.noteType
      )
    }
    guard StructuredNoteMarkdownRenderer().render(newRun.document) == newRun.markdown
    else {
      throw VoiceNoteStructuredRunStoreError.markdownMismatch
    }

    let errorCategory = VoiceNoteStructuredRunWarning.errorCategory(
      for: newRun.partialFailures
    )
    let transaction = M5StructuredRunTransaction(
      sessionID: newRun.sessionID,
      runID: newRun.id,
      createdAt: newRun.createdAt,
      providerID: newRun.metadata.providerID,
      modelID: newRun.metadata.modelID,
      configurationHash: newRun.metadata.configurationHash,
      errorCategory: errorCategory
    )
    try await fileStore.commitM5StructuredRun(
      transaction: transaction,
      document: newRun.document,
      markdown: newRun.markdown
    )
    let run: ProcessingRunDTO
    do {
      try Task.checkCancellation()
      run = try await history.appendRun(
        NewProcessingRun(
          id: newRun.id,
          ownerKind: .voiceNote,
          ownerID: newRun.sessionID,
          createdAt: newRun.createdAt,
          providerID: newRun.metadata.providerID,
          modelID: newRun.metadata.modelID,
          configurationHash: newRun.metadata.configurationHash,
          outputText: newRun.markdown,
          status: .succeeded,
          errorCategory: errorCategory
        )
      )
    } catch {
      do {
        try await fileStore.rollbackM5StructuredRun(
          sessionID: newRun.sessionID,
          runID: newRun.id
        )
      } catch {
        throw VoiceNoteStructuredRunStoreError.rollbackFailed(newRun.id)
      }
      throw error
    }
    try? await fileStore.completeM5StructuredRun(
      sessionID: newRun.sessionID,
      runID: newRun.id
    )
    return VoiceNoteStructuredRun(
      run: run,
      document: newRun.document,
      markdown: newRun.markdown
    )
  }

  func appendFailure(
    sessionID: UUID,
    runID: UUID = UUID(),
    createdAt: Date = Date(),
    metadata: VoiceNoteStructuredRunMetadata,
    errorCategory: String
  ) async throws -> ProcessingRunDTO {
    try Self.validate(metadata)
    guard !errorCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw VoiceNoteStructuredRunStoreError.invalidErrorCategory
    }
    try Task.checkCancellation()
    return try await history.appendRun(
      NewProcessingRun(
        id: runID,
        ownerKind: .voiceNote,
        ownerID: sessionID,
        createdAt: createdAt,
        providerID: metadata.providerID,
        modelID: metadata.modelID,
        configurationHash: metadata.configurationHash,
        outputText: nil,
        status: .failed,
        errorCategory: errorCategory
      )
    )
  }

  func runs(sessionID: UUID) async throws -> [ProcessingRunDTO] {
    try await history.runs(ownerKind: .voiceNote, ownerID: sessionID)
  }

  func sourceDuration(sessionID: UUID) async throws -> TimeInterval {
    guard let duration = try await history.m5SourceDuration(sessionID: sessionID)
    else {
      throw VoiceNoteStructuredRunStoreError.sessionNotFound(sessionID)
    }
    return duration
  }

  func reconcileM5StructuredRuns() async throws {
    let transactions = try await fileStore.pendingM5StructuredRunTransactions()
    for transaction in transactions {
      let existing = try await history.runs(
        ownerKind: .voiceNote,
        ownerID: transaction.sessionID
      ).first(where: { $0.id == transaction.runID })
      if let existing {
        guard existing.status == .succeeded else {
          throw VoiceNoteStructuredRunStoreError.incompleteRun(transaction.runID)
        }
        let artifacts = try await fileStore.readM5StructuredRun(
          sessionID: transaction.sessionID,
          runID: transaction.runID
        )
        guard
          existing.providerID == transaction.providerID,
          existing.modelID == transaction.modelID,
          existing.configurationHash == transaction.configurationHash,
          existing.errorCategory == transaction.errorCategory,
          existing.outputText == artifacts.markdown
        else {
          throw VoiceNoteStructuredRunStoreError.outputMismatch(transaction.runID)
        }
        try await fileStore.completeM5StructuredRun(
          sessionID: transaction.sessionID,
          runID: transaction.runID
        )
        continue
      }

      let artifacts: M5StructuredRunArtifacts
      do {
        artifacts = try await fileStore.readM5StructuredRun(
          sessionID: transaction.sessionID,
          runID: transaction.runID
        )
        guard
          StructuredNoteMarkdownRenderer().render(artifacts.document)
            == artifacts.markdown
        else {
          throw VoiceNoteStructuredRunStoreError.markdownMismatch
        }
      } catch {
        try await fileStore.rollbackM5StructuredRun(
          sessionID: transaction.sessionID,
          runID: transaction.runID
        )
        continue
      }

      _ = try await history.appendRun(
        NewProcessingRun(
          id: transaction.runID,
          ownerKind: .voiceNote,
          ownerID: transaction.sessionID,
          createdAt: transaction.createdAt,
          providerID: transaction.providerID,
          modelID: transaction.modelID,
          configurationHash: transaction.configurationHash,
          outputText: artifacts.markdown,
          status: .succeeded,
          errorCategory: transaction.errorCategory
        )
      )
      try await fileStore.completeM5StructuredRun(
        sessionID: transaction.sessionID,
        runID: transaction.runID
      )
    }
  }

  func read(sessionID: UUID, runID: UUID) async throws
    -> VoiceNoteStructuredRun?
  {
    guard
      let run = try await history.runs(
        ownerKind: .voiceNote,
        ownerID: sessionID
      ).first(where: { $0.id == runID })
    else {
      return nil
    }
    guard run.status == .succeeded else {
      return VoiceNoteStructuredRun(run: run, document: nil, markdown: nil)
    }
    let artifacts = try await fileStore.readM5StructuredRun(
      sessionID: sessionID,
      runID: runID
    )
    guard run.outputText == artifacts.markdown else {
      throw VoiceNoteStructuredRunStoreError.outputMismatch(runID)
    }
    return VoiceNoteStructuredRun(
      run: run,
      document: artifacts.document,
      markdown: artifacts.markdown
    )
  }

  private static func validate(_ metadata: VoiceNoteStructuredRunMetadata) throws {
    guard
      !metadata.providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !metadata.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !metadata.configurationHash.trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty
    else {
      throw VoiceNoteStructuredRunStoreError.invalidMetadata
    }
  }
}

extension SessionFileStore: M5StructuredRunAssetStoring {
  func commitM5StructuredRun(
    transaction: M5StructuredRunTransaction,
    document: ProcessedDocument,
    markdown: String
  ) throws {
    let sessionID = transaction.sessionID
    let runID = transaction.runID
    let createdAt = transaction.createdAt
    var current = try manifest(sessionID: sessionID)
    let paths = Self.m5Paths(runID: runID)
    let fileManager = FileManager.default
    let sessionURL = sessionsRootURL.appendingPathComponent(
      sessionID.uuidString,
      isDirectory: true
    )
    let runsURL = sessionURL.appendingPathComponent("runs", isDirectory: true)
    let finalURL = runsURL.appendingPathComponent(runID.uuidString, isDirectory: true)
    let partialURL = runsURL.appendingPathComponent(
      "\(runID.uuidString).partial",
      isDirectory: true
    )
    let markerURL = runsURL.appendingPathComponent(
      "\(runID.uuidString).transaction.json"
    )
    let markerPartialURL = runsURL.appendingPathComponent(
      "\(runID.uuidString).transaction.partial"
    )

    try fileManager.createDirectory(at: runsURL, withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: partialURL.path) {
      try fileManager.removeItem(at: partialURL)
    }
    if fileManager.fileExists(atPath: markerPartialURL.path) {
      try fileManager.removeItem(at: markerPartialURL)
    }
    guard
      !fileManager.fileExists(atPath: finalURL.path),
      !fileManager.fileExists(atPath: markerURL.path),
      !current.assets.contains(where: {
        $0.relativePath == paths.document || $0.relativePath == paths.markdown
      })
    else {
      throw SessionFileStoreError.assetAlreadyExists
    }

    let documentData = try Self.m5Encoder.encode(document)
    let markdownData = Data(markdown.utf8)
    do {
      try Self.m5Write(Self.m5Encoder.encode(transaction), to: markerPartialURL)
      try fileManager.moveItem(at: markerPartialURL, to: markerURL)
      try Self.m5SynchronizeDirectory(runsURL)
      try fileManager.createDirectory(at: partialURL, withIntermediateDirectories: false)
      try Task.checkCancellation()
      try Self.m5Write(documentData, to: partialURL.appendingPathComponent("document.json"))
      try Task.checkCancellation()
      try Self.m5Write(markdownData, to: partialURL.appendingPathComponent("note.md"))
      try Task.checkCancellation()
      try fileManager.moveItem(at: partialURL, to: finalURL)
      try Self.m5SynchronizeDirectory(runsURL)

      current.assets.append(
        Self.m5Asset(
          kind: .processingDocument,
          relativePath: paths.document,
          data: documentData,
          createdAt: createdAt
        )
      )
      current.assets.append(
        Self.m5Asset(
          kind: .processingMarkdown,
          relativePath: paths.markdown,
          data: markdownData,
          createdAt: createdAt
        )
      )
      current.updatedAt = createdAt
      do {
        try Self.m5WriteManifest(
          current,
          at: sessionURL,
          transactionID: runID,
          fileManager: fileManager
        )
      } catch {
        try? fileManager.removeItem(at: finalURL)
        throw error
      }
    } catch {
      try? fileManager.removeItem(at: partialURL)
      try? fileManager.removeItem(at: markerPartialURL)
      try? fileManager.removeItem(at: markerURL)
      try? Self.m5SynchronizeDirectory(runsURL)
      throw error
    }
  }

  func rollbackM5StructuredRun(
    sessionID: UUID,
    runID: UUID
  ) throws {
    var current = try manifest(sessionID: sessionID)
    let paths = Self.m5Paths(runID: runID)
    let fileManager = FileManager.default
    let sessionURL = sessionsRootURL.appendingPathComponent(
      sessionID.uuidString,
      isDirectory: true
    )
    let runsURL = sessionURL.appendingPathComponent("runs", isDirectory: true)
    let finalURL = runsURL.appendingPathComponent(runID.uuidString, isDirectory: true)
    let partialURL = runsURL.appendingPathComponent(
      "\(runID.uuidString).partial",
      isDirectory: true
    )
    let markerURL = runsURL.appendingPathComponent(
      "\(runID.uuidString).transaction.json"
    )
    let markerPartialURL = runsURL.appendingPathComponent(
      "\(runID.uuidString).transaction.partial"
    )
    let originalCount = current.assets.count
    current.assets.removeAll {
      $0.relativePath == paths.document || $0.relativePath == paths.markdown
    }
    if current.assets.count != originalCount {
      current.updatedAt = Date()
      try Self.m5WriteManifest(
        current,
        at: sessionURL,
        transactionID: runID,
        fileManager: fileManager
      )
    }
    if fileManager.fileExists(atPath: partialURL.path) {
      try fileManager.removeItem(at: partialURL)
    }
    if fileManager.fileExists(atPath: finalURL.path) {
      try fileManager.removeItem(at: finalURL)
    }
    if fileManager.fileExists(atPath: markerURL.path) {
      try fileManager.removeItem(at: markerURL)
    }
    if fileManager.fileExists(atPath: markerPartialURL.path) {
      try fileManager.removeItem(at: markerPartialURL)
    }
    if fileManager.fileExists(atPath: runsURL.path) {
      try Self.m5SynchronizeDirectory(runsURL)
    }
  }

  func completeM5StructuredRun(
    sessionID: UUID,
    runID: UUID
  ) throws {
    let runsURL =
      sessionsRootURL
      .appendingPathComponent(sessionID.uuidString, isDirectory: true)
      .appendingPathComponent("runs", isDirectory: true)
    let markerURL = runsURL.appendingPathComponent(
      "\(runID.uuidString).transaction.json"
    )
    guard FileManager.default.fileExists(atPath: markerURL.path) else { return }
    try FileManager.default.removeItem(at: markerURL)
    try Self.m5SynchronizeDirectory(runsURL)
  }

  func pendingM5StructuredRunTransactions() throws
    -> [M5StructuredRunTransaction]
  {
    let fileManager = FileManager.default
    var transactions: [M5StructuredRunTransaction] = []
    for sessionID in try sessionIDs() {
      let runsURL =
        sessionsRootURL
        .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        .appendingPathComponent("runs", isDirectory: true)
      guard fileManager.fileExists(atPath: runsURL.path) else { continue }
      let contents = try fileManager.contentsOfDirectory(
        at: runsURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
      var removedPartial = false
      for url in contents where url.lastPathComponent.hasSuffix(".partial") {
        try fileManager.removeItem(at: url)
        removedPartial = true
      }
      if removedPartial {
        try Self.m5SynchronizeDirectory(runsURL)
      }
      for url in contents where url.lastPathComponent.hasSuffix(".transaction.json") {
        let transaction = try Self.m5Decoder.decode(
          M5StructuredRunTransaction.self,
          from: Data(contentsOf: url)
        )
        guard
          transaction.version == M5StructuredRunTransaction.currentVersion,
          transaction.sessionID == sessionID,
          url.deletingPathExtension().deletingPathExtension().lastPathComponent
            == transaction.runID.uuidString
        else {
          throw VoiceNoteStructuredRunStoreError.invalidTransactionMarker
        }
        transactions.append(transaction)
      }
    }
    return transactions.sorted {
      if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
      return $0.runID.uuidString < $1.runID.uuidString
    }
  }

  func readM5StructuredRun(
    sessionID: UUID,
    runID: UUID
  ) throws -> M5StructuredRunArtifacts {
    let current = try manifest(sessionID: sessionID)
    let paths = Self.m5Paths(runID: runID)
    guard
      let documentAsset = current.assets.first(where: {
        $0.kind == .processingDocument && $0.relativePath == paths.document
      }),
      let markdownAsset = current.assets.first(where: {
        $0.kind == .processingMarkdown && $0.relativePath == paths.markdown
      })
    else {
      throw VoiceNoteStructuredRunStoreError.incompleteRun(runID)
    }
    let document = try readJSON(
      ProcessedDocument.self,
      sessionID: sessionID,
      relativePath: paths.document,
      expectedSHA256: documentAsset.sha256
    )
    let markdownData = try readData(
      sessionID: sessionID,
      relativePath: paths.markdown,
      expectedSHA256: markdownAsset.sha256
    )
    guard let markdown = String(data: markdownData, encoding: .utf8) else {
      throw VoiceNoteStructuredRunStoreError.invalidMarkdownEncoding(runID)
    }
    return M5StructuredRunArtifacts(document: document, markdown: markdown)
  }

  private static func m5Paths(runID: UUID) -> (
    document: String,
    markdown: String
  ) {
    let directory = "runs/\(runID.uuidString)"
    return ("\(directory)/document.json", "\(directory)/note.md")
  }

  private static var m5Encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private static var m5Decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return decoder
  }

  private static func m5Asset(
    kind: SessionManifest.Asset.Kind,
    relativePath: String,
    data: Data,
    createdAt: Date
  ) -> SessionManifest.Asset {
    SessionManifest.Asset(
      kind: kind,
      relativePath: relativePath,
      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      byteCount: Int64(data.count),
      createdAt: createdAt
    )
  }

  private static func m5Write(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: [])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path
    )
    let handle = try FileHandle(forWritingTo: url)
    try handle.synchronize()
    try handle.close()
  }

  private static func m5SynchronizeDirectory(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  private static func m5WriteManifest(
    _ manifest: SessionManifest,
    at sessionURL: URL,
    transactionID: UUID,
    fileManager: FileManager
  ) throws {
    let destination = sessionURL.appendingPathComponent(manifestRelativePath)
    let partialURL = sessionURL.appendingPathComponent(
      "\(manifestRelativePath).\(transactionID.uuidString).partial"
    )
    do {
      try m5Write(m5Encoder.encode(manifest), to: partialURL)
      _ = try fileManager.replaceItemAt(
        destination,
        withItemAt: partialURL,
        backupItemName: nil,
        options: []
      )
      try m5SynchronizeDirectory(sessionURL)
    } catch {
      try? fileManager.removeItem(at: partialURL)
      throw error
    }
  }
}

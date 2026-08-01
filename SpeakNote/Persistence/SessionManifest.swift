import Foundation

struct SessionManifest: Codable, Equatable, Sendable {
  static let currentVersion = 1

  enum Source: String, Codable, Sendable {
    case imported
    case recorded
  }

  enum State: String, Codable, Sendable {
    case ready
    case processing
    case completed
    case interrupted
    case retryRequired
    case needsRepair
    case pendingDeletion
  }

  struct Asset: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
      case importedOriginal
      case captureSegment
      case archive
      case audioChunk
      case rawChunkResponse
      case rawTranscriptJSON
      case rawTranscriptMarkdown
      case processingDocument
      case processingMarkdown
      case checkpoint
    }

    let id: UUID
    let kind: Kind
    let relativePath: String
    let sha256: String
    let byteCount: Int64
    let createdAt: Date

    init(
      id: UUID = UUID(),
      kind: Kind,
      relativePath: String,
      sha256: String,
      byteCount: Int64,
      createdAt: Date = Date()
    ) {
      self.id = id
      self.kind = kind
      self.relativePath = relativePath
      self.sha256 = sha256
      self.byteCount = byteCount
      self.createdAt = createdAt
    }
  }

  let version: Int
  let sessionID: UUID
  let createdAt: Date
  var updatedAt: Date
  var source: Source
  var state: State
  var assets: [Asset]

  init(
    version: Int = Self.currentVersion,
    sessionID: UUID,
    createdAt: Date = Date(),
    updatedAt: Date? = nil,
    source: Source,
    state: State = .ready,
    assets: [Asset] = []
  ) {
    self.version = version
    self.sessionID = sessionID
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
    self.source = source
    self.state = state
    self.assets = assets
  }
}

struct TranscriptionCheckpoint: Codable, Equatable, Sendable {
  static let currentVersion = 2

  struct Chunk: Codable, Equatable, Sendable {
    let index: Int
    let audioRelativePath: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let byteCount: Int64
    let sha256: String
  }

  struct CompletedChunk: Codable, Equatable, Sendable {
    let index: Int
    let responseRelativePath: String
    let responseSHA256: String
  }

  let version: Int
  let jobID: UUID
  let sessionID: UUID
  let totalChunks: Int
  let sourceRelativePath: String
  let sourceDuration: TimeInterval
  var transcriptionConfiguration: TranscriptionConfiguration?
  var chunks: [Chunk]
  var completedChunks: [CompletedChunk]
  var updatedAt: Date

  init(
    version: Int = Self.currentVersion,
    jobID: UUID,
    sessionID: UUID,
    totalChunks: Int,
    sourceRelativePath: String = "",
    sourceDuration: TimeInterval = 0,
    transcriptionConfiguration: TranscriptionConfiguration? = nil,
    chunks: [Chunk] = [],
    completedChunks: [CompletedChunk] = [],
    updatedAt: Date = Date()
  ) {
    self.version = version
    self.jobID = jobID
    self.sessionID = sessionID
    self.totalChunks = totalChunks
    self.sourceRelativePath = sourceRelativePath
    self.sourceDuration = sourceDuration
    self.transcriptionConfiguration = transcriptionConfiguration
    self.chunks = chunks
    self.completedChunks = completedChunks
    self.updatedAt = updatedAt
  }
}

struct RecordingJournal: Codable, Equatable, Sendable {
  static let currentVersion = 1

  enum State: String, Codable, Sendable {
    case recording
    case paused
    case interrupted
  }

  let version: Int
  let sessionID: UUID
  let startedAt: Date
  var updatedAt: Date
  let segmentDuration: TimeInterval
  var lastClosedSegmentIndex: Int?
  var state: State

  init(
    version: Int = Self.currentVersion,
    sessionID: UUID,
    startedAt: Date,
    updatedAt: Date? = nil,
    segmentDuration: TimeInterval,
    lastClosedSegmentIndex: Int? = nil,
    state: State
  ) {
    self.version = version
    self.sessionID = sessionID
    self.startedAt = startedAt
    self.updatedAt = updatedAt ?? startedAt
    self.segmentDuration = segmentDuration
    self.lastClosedSegmentIndex = lastClosedSegmentIndex
    self.state = state
  }
}

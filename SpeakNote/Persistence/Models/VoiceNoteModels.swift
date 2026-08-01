import Foundation
import SwiftData

enum VoiceNoteSource: String, Codable, CaseIterable, Sendable {
  case imported
  case recorded
}

enum VoiceNoteSessionStatus: String, Codable, CaseIterable, Sendable {
  case importing
  case recording
  case paused
  case ready
  case preprocessing
  case transcribing
  case merging
  case completed
  case cancelled
  case retryRequired
  case interrupted
  case recoveryAvailable
  case needsRepair
  case pendingDeletion
}

enum TranscriptionJobStage: String, Codable, CaseIterable, Sendable {
  case queued
  case preprocessing
  case chunking
  case transcribing
  case merging
  case exporting
  case completed
  case cancelled
  case retryRequired
}

struct NewRecordingSession: Equatable, Sendable {
  let id: UUID
  let title: String
  let createdAt: Date
  let source: VoiceNoteSource
  let status: VoiceNoteSessionStatus
  let duration: TimeInterval

  init(
    id: UUID = UUID(),
    title: String,
    createdAt: Date = Date(),
    source: VoiceNoteSource,
    status: VoiceNoteSessionStatus,
    duration: TimeInterval
  ) {
    self.id = id
    self.title = title
    self.createdAt = createdAt
    self.source = source
    self.status = status
    self.duration = duration
  }
}

struct RecordingSessionDTO: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let title: String
  let createdAt: Date
  let updatedAt: Date
  let source: VoiceNoteSource
  let status: VoiceNoteSessionStatus
  let duration: TimeInterval
  let currentJobID: UUID?
  let needsRepair: Bool
}

struct NewTranscriptionJob: Equatable, Sendable {
  let id: UUID
  let sessionID: UUID
  let createdAt: Date
  let stage: TranscriptionJobStage
  let completedChunks: Int
  let totalChunks: Int
  let checkpointRelativePath: String?

  init(
    id: UUID = UUID(),
    sessionID: UUID,
    createdAt: Date = Date(),
    stage: TranscriptionJobStage = .queued,
    completedChunks: Int = 0,
    totalChunks: Int = 0,
    checkpointRelativePath: String? = nil
  ) {
    self.id = id
    self.sessionID = sessionID
    self.createdAt = createdAt
    self.stage = stage
    self.completedChunks = completedChunks
    self.totalChunks = totalChunks
    self.checkpointRelativePath = checkpointRelativePath
  }
}

struct TranscriptionJobDTO: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let sessionID: UUID
  let createdAt: Date
  let updatedAt: Date
  let stage: TranscriptionJobStage
  let completedChunks: Int
  let totalChunks: Int
  let checkpointRelativePath: String?
  let errorCategory: String?
}

@Model
final class RecordingSessionModel {
  @Attribute(.unique) var id: UUID
  var title: String
  var createdAt: Date
  var updatedAt: Date
  var sourceRawValue: String
  var statusRawValue: String
  var duration: TimeInterval
  var currentJobID: UUID?
  var needsRepair: Bool

  init(
    id: UUID,
    title: String,
    createdAt: Date,
    updatedAt: Date,
    sourceRawValue: String,
    statusRawValue: String,
    duration: TimeInterval,
    currentJobID: UUID? = nil,
    needsRepair: Bool = false
  ) {
    self.id = id
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.sourceRawValue = sourceRawValue
    self.statusRawValue = statusRawValue
    self.duration = duration
    self.currentJobID = currentJobID
    self.needsRepair = needsRepair
  }
}

@Model
final class TranscriptionJobModel {
  @Attribute(.unique) var id: UUID
  var sessionID: UUID
  var createdAt: Date
  var updatedAt: Date
  var stageRawValue: String
  var completedChunks: Int
  var totalChunks: Int
  var checkpointRelativePath: String?
  var errorCategory: String?

  init(
    id: UUID,
    sessionID: UUID,
    createdAt: Date,
    updatedAt: Date,
    stageRawValue: String,
    completedChunks: Int,
    totalChunks: Int,
    checkpointRelativePath: String?,
    errorCategory: String? = nil
  ) {
    self.id = id
    self.sessionID = sessionID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.stageRawValue = stageRawValue
    self.completedChunks = completedChunks
    self.totalChunks = totalChunks
    self.checkpointRelativePath = checkpointRelativePath
    self.errorCategory = errorCategory
  }
}

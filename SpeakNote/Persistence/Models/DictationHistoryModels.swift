import Foundation
import SwiftData

enum DictationRecordStatus: String, Codable, Sendable {
    case transcribed
    case cancelled
    case failed
}

enum ProcessingRunOwnerKind: String, Codable, Sendable {
    case dictation
    case voiceNote
}

enum ProcessingRunStatus: String, Codable, Sendable {
    case succeeded
    case failed
}

struct NewDictationRecord: Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let rawTranscript: String
    let detectedLanguage: String?
    let status: DictationRecordStatus

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        rawTranscript: String,
        detectedLanguage: String?,
        status: DictationRecordStatus = .transcribed
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawTranscript = rawTranscript
        self.detectedLanguage = detectedLanguage
        self.status = status
    }
}

struct DictationRecordDTO: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let rawTranscript: String
    let detectedLanguage: String?
    let status: DictationRecordStatus
}

struct NewProcessingRun: Equatable, Sendable {
    let id: UUID
    let ownerKind: ProcessingRunOwnerKind
    let ownerID: UUID
    let createdAt: Date
    let providerID: String
    let modelID: String
    let configurationHash: String
    let outputText: String?
    let status: ProcessingRunStatus
    let errorCategory: String?

    init(
        id: UUID = UUID(),
        ownerKind: ProcessingRunOwnerKind = .dictation,
        ownerID: UUID,
        createdAt: Date = Date(),
        providerID: String,
        modelID: String,
        configurationHash: String,
        outputText: String?,
        status: ProcessingRunStatus,
        errorCategory: String? = nil
    ) {
        self.id = id
        self.ownerKind = ownerKind
        self.ownerID = ownerID
        self.createdAt = createdAt
        self.providerID = providerID
        self.modelID = modelID
        self.configurationHash = configurationHash
        self.outputText = outputText
        self.status = status
        self.errorCategory = errorCategory
    }
}

struct ProcessingRunDTO: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let ownerKind: ProcessingRunOwnerKind
    let ownerID: UUID
    let createdAt: Date
    let providerID: String
    let modelID: String
    let configurationHash: String
    let outputText: String?
    let status: ProcessingRunStatus
    let errorCategory: String?
}

@Model
final class DictationRecordModel {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var rawTranscript: String
    var detectedLanguage: String?
    var statusRawValue: String

    init(
        id: UUID,
        createdAt: Date,
        rawTranscript: String,
        detectedLanguage: String?,
        statusRawValue: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawTranscript = rawTranscript
        self.detectedLanguage = detectedLanguage
        self.statusRawValue = statusRawValue
    }
}

@Model
final class ProcessingRunModel {
    @Attribute(.unique) var id: UUID
    var ownerKindRawValue: String
    var ownerID: UUID
    var createdAt: Date
    var providerID: String
    var modelID: String
    var configurationHash: String
    var outputText: String?
    var statusRawValue: String
    var errorCategory: String?

    init(
        id: UUID,
        ownerKindRawValue: String,
        ownerID: UUID,
        createdAt: Date,
        providerID: String,
        modelID: String,
        configurationHash: String,
        outputText: String?,
        statusRawValue: String,
        errorCategory: String?
    ) {
        self.id = id
        self.ownerKindRawValue = ownerKindRawValue
        self.ownerID = ownerID
        self.createdAt = createdAt
        self.providerID = providerID
        self.modelID = modelID
        self.configurationHash = configurationHash
        self.outputText = outputText
        self.statusRawValue = statusRawValue
        self.errorCategory = errorCategory
    }
}

import Foundation
import SwiftData

enum DictationHistoryRepositoryError: Error, Equatable, Sendable {
    case duplicateIdentifier(UUID)
    case invalidRawTranscript
    case invalidProcessingRun
    case ownerNotFound(UUID)
    case invalidStoredValue
}

protocol DictationHistoryStoring: Actor {
    func createRecord(_ record: NewDictationRecord) throws -> DictationRecordDTO
    func record(id: UUID) throws -> DictationRecordDTO?
    func records() throws -> [DictationRecordDTO]
    func updateRecordStatus(
        id: UUID,
        status: DictationRecordStatus
    ) throws -> DictationRecordDTO
    func appendRun(_ run: NewProcessingRun) throws -> ProcessingRunDTO
    func runs(ownerKind: ProcessingRunOwnerKind, ownerID: UUID) throws -> [ProcessingRunDTO]
    func deleteRecord(id: UUID) throws
}

enum SessionRepositoryError: Error, Equatable, Sendable {
    case duplicateIdentifier(UUID)
    case invalidSession
    case invalidJob
    case sessionNotFound(UUID)
    case jobNotFound(UUID)
    case invalidStoredValue
}

protocol VoiceNoteSessionStoring: Actor {
    func createSession(_ session: NewRecordingSession) throws -> RecordingSessionDTO
    func session(id: UUID) throws -> RecordingSessionDTO?
    func sessions() throws -> [RecordingSessionDTO]
    func updateSession(
        id: UUID,
        status: VoiceNoteSessionStatus,
        duration: TimeInterval,
        currentJobID: UUID?,
        updatedAt: Date
    ) throws -> RecordingSessionDTO
    func renameSession(id: UUID, title: String, updatedAt: Date) throws
        -> RecordingSessionDTO
    func markSessionNeedsRepair(id: UUID, updatedAt: Date) throws
        -> RecordingSessionDTO
    func createJob(_ job: NewTranscriptionJob) throws -> TranscriptionJobDTO
    func job(id: UUID) throws -> TranscriptionJobDTO?
    func jobs(sessionID: UUID) throws -> [TranscriptionJobDTO]
    func updateJob(
        id: UUID,
        stage: TranscriptionJobStage,
        completedChunks: Int,
        totalChunks: Int,
        checkpointRelativePath: String?,
        errorCategory: String?,
        updatedAt: Date
    ) throws -> TranscriptionJobDTO
    func deleteSessionMetadata(id: UUID) throws
}

enum SpeakNoteModelContainer {
    static func persistent() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SpeakNoteSchemaV2.self)
        return try ModelContainer(
            for: schema,
            migrationPlan: SpeakNoteMigrationPlan.self,
            configurations: ModelConfiguration(
                "SpeakNoteHistory",
                schema: schema,
                groupContainer: .none,
                cloudKitDatabase: .none
            )
        )
    }

    static func persistent(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SpeakNoteSchemaV2.self)
        return try ModelContainer(
            for: schema,
            migrationPlan: SpeakNoteMigrationPlan.self,
            configurations: ModelConfiguration(
                "SpeakNoteHistory",
                schema: schema,
                url: url,
                cloudKitDatabase: .none
            )
        )
    }

    static func inMemory() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SpeakNoteSchemaV2.self)
        return try ModelContainer(
            for: schema,
            migrationPlan: SpeakNoteMigrationPlan.self,
            configurations: ModelConfiguration(
                "SpeakNoteHistoryTests",
                schema: schema,
                isStoredInMemoryOnly: true,
                groupContainer: .none,
                cloudKitDatabase: .none
            )
        )
    }
}

@ModelActor
actor SwiftDataSessionRepository: DictationHistoryStoring, VoiceNoteSessionStoring {
    func createRecord(_ record: NewDictationRecord) throws -> DictationRecordDTO {
        guard !record.rawTranscript.isEmpty else {
            throw DictationHistoryRepositoryError.invalidRawTranscript
        }
        guard try recordModel(id: record.id) == nil else {
            throw DictationHistoryRepositoryError.duplicateIdentifier(record.id)
        }

        let model = DictationRecordModel(
            id: record.id,
            createdAt: record.createdAt,
            rawTranscript: record.rawTranscript,
            detectedLanguage: record.detectedLanguage,
            statusRawValue: record.status.rawValue
        )
        modelContext.insert(model)
        try modelContext.save()
        return try dto(from: model)
    }

    func record(id: UUID) throws -> DictationRecordDTO? {
        try recordModel(id: id).map(dto(from:))
    }

    func records() throws -> [DictationRecordDTO] {
        let models = try modelContext.fetch(FetchDescriptor<DictationRecordModel>())
        return try models
            .map(dto(from:))
            .sorted(by: dictationComesFirst)
    }

    func updateRecordStatus(
        id: UUID,
        status: DictationRecordStatus
    ) throws -> DictationRecordDTO {
        guard let model = try recordModel(id: id) else {
            throw DictationHistoryRepositoryError.ownerNotFound(id)
        }
        model.statusRawValue = status.rawValue
        try modelContext.save()
        return try dto(from: model)
    }

    func appendRun(_ run: NewProcessingRun) throws -> ProcessingRunDTO {
        guard
            !run.providerID.isEmpty,
            !run.modelID.isEmpty,
            !run.configurationHash.isEmpty
        else {
            throw DictationHistoryRepositoryError.invalidProcessingRun
        }
        guard try runModel(id: run.id) == nil else {
            throw DictationHistoryRepositoryError.duplicateIdentifier(run.id)
        }
        switch run.ownerKind {
        case .dictation:
            guard try recordModel(id: run.ownerID) != nil else {
                throw DictationHistoryRepositoryError.ownerNotFound(run.ownerID)
            }
        case .voiceNote:
            guard try sessionModel(id: run.ownerID) != nil else {
                throw DictationHistoryRepositoryError.ownerNotFound(run.ownerID)
            }
        }

        let model = ProcessingRunModel(
            id: run.id,
            ownerKindRawValue: run.ownerKind.rawValue,
            ownerID: run.ownerID,
            createdAt: run.createdAt,
            providerID: run.providerID,
            modelID: run.modelID,
            configurationHash: run.configurationHash,
            outputText: run.outputText,
            statusRawValue: run.status.rawValue,
            errorCategory: run.errorCategory
        )
        modelContext.insert(model)
        try modelContext.save()
        return try dto(from: model)
    }

    func runs(
        ownerKind: ProcessingRunOwnerKind,
        ownerID: UUID
    ) throws -> [ProcessingRunDTO] {
        let ownerKindRawValue = ownerKind.rawValue
        let descriptor = FetchDescriptor<ProcessingRunModel>(
            predicate: #Predicate {
                $0.ownerKindRawValue == ownerKindRawValue && $0.ownerID == ownerID
            }
        )
        let models = try modelContext.fetch(descriptor)
        return try models
            .map(dto(from:))
            .sorted(by: processingRunComesFirst)
    }

    func deleteRecord(id: UUID) throws {
        guard let record = try recordModel(id: id) else {
            return
        }

        let ownerKindRawValue = ProcessingRunOwnerKind.dictation.rawValue
        let descriptor = FetchDescriptor<ProcessingRunModel>(
            predicate: #Predicate {
                $0.ownerKindRawValue == ownerKindRawValue && $0.ownerID == id
            }
        )
        for run in try modelContext.fetch(descriptor) {
            modelContext.delete(run)
        }
        modelContext.delete(record)
        try modelContext.save()
    }

    func createSession(
        _ session: NewRecordingSession
    ) throws -> RecordingSessionDTO {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
            session.duration.isFinite,
            session.duration >= 0
        else {
            throw SessionRepositoryError.invalidSession
        }
        guard try sessionModel(id: session.id) == nil else {
            throw SessionRepositoryError.duplicateIdentifier(session.id)
        }
        let model = RecordingSessionModel(
            id: session.id,
            title: title,
            createdAt: session.createdAt,
            updatedAt: session.createdAt,
            sourceRawValue: session.source.rawValue,
            statusRawValue: session.status.rawValue,
            duration: session.duration
        )
        modelContext.insert(model)
        try modelContext.save()
        return try dto(from: model)
    }

    func session(id: UUID) throws -> RecordingSessionDTO? {
        try sessionModel(id: id).map(dto(from:))
    }

    func sessions() throws -> [RecordingSessionDTO] {
        try modelContext.fetch(FetchDescriptor<RecordingSessionModel>())
            .map(dto(from:))
            .sorted {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    func updateSession(
        id: UUID,
        status: VoiceNoteSessionStatus,
        duration: TimeInterval,
        currentJobID: UUID?,
        updatedAt: Date
    ) throws -> RecordingSessionDTO {
        guard let model = try sessionModel(id: id) else {
            throw SessionRepositoryError.sessionNotFound(id)
        }
        guard duration.isFinite, duration >= 0 else {
            throw SessionRepositoryError.invalidSession
        }
        model.statusRawValue = status.rawValue
        model.duration = duration
        model.currentJobID = currentJobID
        model.updatedAt = updatedAt
        try modelContext.save()
        return try dto(from: model)
    }

    func renameSession(
        id: UUID,
        title: String,
        updatedAt: Date
    ) throws -> RecordingSessionDTO {
        guard let model = try sessionModel(id: id) else {
            throw SessionRepositoryError.sessionNotFound(id)
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw SessionRepositoryError.invalidSession
        }
        model.title = title
        model.updatedAt = updatedAt
        try modelContext.save()
        return try dto(from: model)
    }

    func markSessionNeedsRepair(
        id: UUID,
        updatedAt: Date
    ) throws -> RecordingSessionDTO {
        guard let model = try sessionModel(id: id) else {
            throw SessionRepositoryError.sessionNotFound(id)
        }
        model.needsRepair = true
        model.statusRawValue = VoiceNoteSessionStatus.needsRepair.rawValue
        model.updatedAt = updatedAt
        try modelContext.save()
        return try dto(from: model)
    }

    func createJob(_ job: NewTranscriptionJob) throws -> TranscriptionJobDTO {
        guard job.completedChunks >= 0,
            job.totalChunks >= 0,
            job.completedChunks <= job.totalChunks
        else {
            throw SessionRepositoryError.invalidJob
        }
        guard try sessionModel(id: job.sessionID) != nil else {
            throw SessionRepositoryError.sessionNotFound(job.sessionID)
        }
        guard try jobModel(id: job.id) == nil else {
            throw SessionRepositoryError.duplicateIdentifier(job.id)
        }
        let model = TranscriptionJobModel(
            id: job.id,
            sessionID: job.sessionID,
            createdAt: job.createdAt,
            updatedAt: job.createdAt,
            stageRawValue: job.stage.rawValue,
            completedChunks: job.completedChunks,
            totalChunks: job.totalChunks,
            checkpointRelativePath: job.checkpointRelativePath
        )
        modelContext.insert(model)
        try modelContext.save()
        return try dto(from: model)
    }

    func job(id: UUID) throws -> TranscriptionJobDTO? {
        try jobModel(id: id).map(dto(from:))
    }

    func jobs(sessionID: UUID) throws -> [TranscriptionJobDTO] {
        let descriptor = FetchDescriptor<TranscriptionJobModel>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        return try modelContext.fetch(descriptor)
            .map(dto(from:))
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
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
        guard let model = try jobModel(id: id) else {
            throw SessionRepositoryError.jobNotFound(id)
        }
        guard completedChunks >= 0,
            totalChunks >= 0,
            completedChunks <= totalChunks
        else {
            throw SessionRepositoryError.invalidJob
        }
        model.stageRawValue = stage.rawValue
        model.completedChunks = completedChunks
        model.totalChunks = totalChunks
        model.checkpointRelativePath = checkpointRelativePath
        model.errorCategory = errorCategory
        model.updatedAt = updatedAt
        try modelContext.save()
        return try dto(from: model)
    }

    func deleteSessionMetadata(id: UUID) throws {
        guard let session = try sessionModel(id: id) else { return }
        let jobsDescriptor = FetchDescriptor<TranscriptionJobModel>(
            predicate: #Predicate { $0.sessionID == id }
        )
        for job in try modelContext.fetch(jobsDescriptor) {
            modelContext.delete(job)
        }
        let ownerKind = ProcessingRunOwnerKind.voiceNote.rawValue
        let runsDescriptor = FetchDescriptor<ProcessingRunModel>(
            predicate: #Predicate {
                $0.ownerKindRawValue == ownerKind && $0.ownerID == id
            }
        )
        for run in try modelContext.fetch(runsDescriptor) {
            modelContext.delete(run)
        }
        modelContext.delete(session)
        try modelContext.save()
    }

    private func recordModel(id: UUID) throws -> DictationRecordModel? {
        var descriptor = FetchDescriptor<DictationRecordModel>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func runModel(id: UUID) throws -> ProcessingRunModel? {
        var descriptor = FetchDescriptor<ProcessingRunModel>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func sessionModel(id: UUID) throws -> RecordingSessionModel? {
        var descriptor = FetchDescriptor<RecordingSessionModel>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func jobModel(id: UUID) throws -> TranscriptionJobModel? {
        var descriptor = FetchDescriptor<TranscriptionJobModel>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func dto(from model: DictationRecordModel) throws -> DictationRecordDTO {
        guard let status = DictationRecordStatus(rawValue: model.statusRawValue) else {
            throw DictationHistoryRepositoryError.invalidStoredValue
        }
        return DictationRecordDTO(
            id: model.id,
            createdAt: model.createdAt,
            rawTranscript: model.rawTranscript,
            detectedLanguage: model.detectedLanguage,
            status: status
        )
    }

    private func dto(from model: ProcessingRunModel) throws -> ProcessingRunDTO {
        guard
            let ownerKind = ProcessingRunOwnerKind(rawValue: model.ownerKindRawValue),
            let status = ProcessingRunStatus(rawValue: model.statusRawValue)
        else {
            throw DictationHistoryRepositoryError.invalidStoredValue
        }
        return ProcessingRunDTO(
            id: model.id,
            ownerKind: ownerKind,
            ownerID: model.ownerID,
            createdAt: model.createdAt,
            providerID: model.providerID,
            modelID: model.modelID,
            configurationHash: model.configurationHash,
            outputText: model.outputText,
            status: status,
            errorCategory: model.errorCategory
        )
    }

    private func dto(from model: RecordingSessionModel) throws -> RecordingSessionDTO {
        guard
            let source = VoiceNoteSource(rawValue: model.sourceRawValue),
            let status = VoiceNoteSessionStatus(rawValue: model.statusRawValue)
        else {
            throw SessionRepositoryError.invalidStoredValue
        }
        return RecordingSessionDTO(
            id: model.id,
            title: model.title,
            createdAt: model.createdAt,
            updatedAt: model.updatedAt,
            source: source,
            status: status,
            duration: model.duration,
            currentJobID: model.currentJobID,
            needsRepair: model.needsRepair
        )
    }

    private func dto(from model: TranscriptionJobModel) throws -> TranscriptionJobDTO {
        guard let stage = TranscriptionJobStage(rawValue: model.stageRawValue) else {
            throw SessionRepositoryError.invalidStoredValue
        }
        return TranscriptionJobDTO(
            id: model.id,
            sessionID: model.sessionID,
            createdAt: model.createdAt,
            updatedAt: model.updatedAt,
            stage: stage,
            completedChunks: model.completedChunks,
            totalChunks: model.totalChunks,
            checkpointRelativePath: model.checkpointRelativePath,
            errorCategory: model.errorCategory
        )
    }

    private func dictationComesFirst(
        _ lhs: DictationRecordDTO,
        _ rhs: DictationRecordDTO
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func processingRunComesFirst(
        _ lhs: ProcessingRunDTO,
        _ rhs: ProcessingRunDTO
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

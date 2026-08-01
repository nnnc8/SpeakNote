import SwiftData

enum SpeakNoteSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            DictationRecordModel.self,
            ProcessingRunModel.self,
            RecordingSessionModel.self,
            TranscriptionJobModel.self,
        ]
    }
}

import SwiftData

enum SpeakNoteSchemaV2: VersionedSchema {
  static let versionIdentifier = Schema.Version(2, 0, 0)

  static var models: [any PersistentModel.Type] {
    [
      DictationRecordModel.self,
      ProcessingRunModel.self,
      RecordingSessionModel.self,
      TranscriptionJobModel.self,
      VocabularyProfileModel.self,
      CustomTermModel.self,
      ReplacementRuleModel.self,
      ReplacementAuditModel.self,
      VocabularyCorrectionObservationModel.self,
      VocabularySuggestionModel.self,
    ]
  }
}

enum SpeakNoteMigrationPlan: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] {
    [SpeakNoteSchemaV1.self, SpeakNoteSchemaV2.self]
  }

  static var stages: [MigrationStage] {
    [
      .lightweight(fromVersion: SpeakNoteSchemaV1.self, toVersion: SpeakNoteSchemaV2.self)
    ]
  }
}

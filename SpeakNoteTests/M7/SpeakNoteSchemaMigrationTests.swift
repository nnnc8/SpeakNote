import Foundation
import SwiftData
import XCTest

@testable import SpeakNote

final class SpeakNoteSchemaMigrationTests: XCTestCase {
  func testV1SampleStoreMigratesToV2AndKeepsExistingData() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpeakNoteM7Migration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("migration.store")
    let fixture = V1Fixture()

    try writeV1Fixture(at: storeURL, fixture: fixture)

    let migratedContainer = try SpeakNoteModelContainer.persistent(at: storeURL)
    let sessionRepository = SwiftDataSessionRepository(modelContainer: migratedContainer)
    let vocabularyRepository = SwiftDataVocabularyRepository(
      modelContainer: migratedContainer
    )

    let record = try await sessionRepository.record(id: fixture.recordID)
    let runs = try await sessionRepository.runs(
      ownerKind: .dictation,
      ownerID: fixture.recordID
    )
    let session = try await sessionRepository.session(id: fixture.sessionID)
    let jobs = try await sessionRepository.jobs(sessionID: fixture.sessionID)
    XCTAssertEqual(record?.rawTranscript, "V1 raw transcript")
    XCTAssertEqual(runs.map(\.id), [fixture.runID])
    XCTAssertEqual(session?.title, "V1 session")
    XCTAssertEqual(jobs.map(\.id), [fixture.jobID])

    let profile = Profile(
      id: fixture.profileID,
      name: "Migrated store profile",
      vocabularyScope: .disabled
    )
    let createdProfile = try await vocabularyRepository.createProfile(profile)
    let storedProfile = try await vocabularyRepository.profile(id: profile.id)
    XCTAssertEqual(createdProfile, profile)
    XCTAssertEqual(storedProfile, profile)
  }

  private func writeV1Fixture(at url: URL, fixture: V1Fixture) throws {
    let schema = Schema(versionedSchema: SpeakNoteSchemaV1.self)
    let container = try ModelContainer(
      for: schema,
      configurations: ModelConfiguration(
        "SpeakNoteV1MigrationFixture",
        schema: schema,
        url: url,
        cloudKitDatabase: .none
      )
    )
    let context = ModelContext(container)
    let createdAt = Date(timeIntervalSince1970: 700)

    context.insert(
      DictationRecordModel(
        id: fixture.recordID,
        createdAt: createdAt,
        rawTranscript: "V1 raw transcript",
        detectedLanguage: "en",
        statusRawValue: DictationRecordStatus.transcribed.rawValue
      )
    )
    context.insert(
      ProcessingRunModel(
        id: fixture.runID,
        ownerKindRawValue: ProcessingRunOwnerKind.dictation.rawValue,
        ownerID: fixture.recordID,
        createdAt: createdAt,
        providerID: "groq",
        modelID: "fixture-model",
        configurationHash: "fixture-hash",
        outputText: "V1 processed output",
        statusRawValue: ProcessingRunStatus.succeeded.rawValue,
        errorCategory: nil
      )
    )
    context.insert(
      RecordingSessionModel(
        id: fixture.sessionID,
        title: "V1 session",
        createdAt: createdAt,
        updatedAt: createdAt,
        sourceRawValue: VoiceNoteSource.imported.rawValue,
        statusRawValue: VoiceNoteSessionStatus.ready.rawValue,
        duration: 42
      )
    )
    context.insert(
      TranscriptionJobModel(
        id: fixture.jobID,
        sessionID: fixture.sessionID,
        createdAt: createdAt,
        updatedAt: createdAt,
        stageRawValue: TranscriptionJobStage.queued.rawValue,
        completedChunks: 0,
        totalChunks: 2,
        checkpointRelativePath: nil
      )
    )
    try context.save()
  }

  private struct V1Fixture {
    let recordID = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
    let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000702")!
    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000703")!
    let jobID = UUID(uuidString: "00000000-0000-0000-0000-000000000704")!
    let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000705")!
  }
}

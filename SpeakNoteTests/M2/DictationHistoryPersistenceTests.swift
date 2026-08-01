import Foundation
import SwiftData
import XCTest
@testable import SpeakNote

final class DictationHistoryPersistenceTests: XCTestCase {
  func testRawRecordRoundTripsBeforeProcessing() async throws {
    let repository = try makeRepository()
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    let createdAt = Date(timeIntervalSince1970: 100)
    let input = NewDictationRecord(
      id: id,
      createdAt: createdAt,
      rawTranscript: "原始逐字稿，保留標點。",
      detectedLanguage: "zh-TW"
    )

    let created = try await repository.createRecord(input)
    let loaded = try await repository.record(id: id)
    let runs = try await repository.runs(ownerKind: .dictation, ownerID: id)

    XCTAssertEqual(created, loaded)
    XCTAssertEqual(created.rawTranscript, input.rawTranscript)
    XCTAssertEqual(created.detectedLanguage, "zh-TW")
    XCTAssertEqual(created.status, .transcribed)
    XCTAssertTrue(runs.isEmpty)
  }

  func testAppendingRunsKeepsEveryOutputAndOrdersDeterministically() async throws {
    let repository = try makeRepository()
    let ownerID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
    _ = try await repository.createRecord(
      NewDictationRecord(
        id: ownerID,
        rawTranscript: "raw",
        detectedLanguage: nil
      )
    )
    let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
    let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000203")!
    let timestamp = Date(timeIntervalSince1970: 200)

    _ = try await repository.appendRun(
      NewProcessingRun(
        id: secondID,
        ownerID: ownerID,
        createdAt: timestamp,
        providerID: "groq",
        modelID: "model-b",
        configurationHash: "hash-b",
        outputText: "second",
        status: .succeeded
      )
    )
    _ = try await repository.appendRun(
      NewProcessingRun(
        id: firstID,
        ownerID: ownerID,
        createdAt: timestamp,
        providerID: "groq",
        modelID: "model-a",
        configurationHash: "hash-a",
        outputText: "first",
        status: .succeeded
      )
    )

    let runs = try await repository.runs(ownerKind: .dictation, ownerID: ownerID)

    XCTAssertEqual(runs.map(\.id), [firstID, secondID])
    XCTAssertEqual(runs.map(\.outputText), ["first", "second"])

    do {
      _ = try await repository.appendRun(
        NewProcessingRun(
          id: firstID,
          ownerID: ownerID,
          providerID: "groq",
          modelID: "replacement",
          configurationHash: "replacement-hash",
          outputText: "replacement",
          status: .succeeded
        )
      )
      XCTFail("Expected append-only storage to reject a duplicate run ID")
    } catch {
      XCTAssertEqual(
        error as? DictationHistoryRepositoryError,
        .duplicateIdentifier(firstID)
      )
    }

    let unchangedRuns = try await repository.runs(
      ownerKind: .dictation,
      ownerID: ownerID
    )
    XCTAssertEqual(unchangedRuns.map(\.outputText), ["first", "second"])
  }

  func testRunCannotBePersistedBeforeRawOwner() async throws {
    let repository = try makeRepository()
    let missingOwner = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
    let run = NewProcessingRun(
      ownerID: missingOwner,
      providerID: "groq",
      modelID: "model",
      configurationHash: "hash",
      outputText: nil,
      status: .failed,
      errorCategory: "network"
    )

    do {
      _ = try await repository.appendRun(run)
      XCTFail("Expected the raw-first invariant to reject an orphaned run")
    } catch {
      XCTAssertEqual(
        error as? DictationHistoryRepositoryError,
        .ownerNotFound(missingOwner)
      )
    }
  }

  func testRecordsUseNewestFirstThenIdentifierOrdering() async throws {
    let repository = try makeRepository()
    let olderID = UUID(uuidString: "00000000-0000-0000-0000-000000000403")!
    let tieFirstID = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
    let tieSecondID = UUID(uuidString: "00000000-0000-0000-0000-000000000402")!

    for record in [
      NewDictationRecord(
        id: olderID,
        createdAt: Date(timeIntervalSince1970: 399),
        rawTranscript: "older",
        detectedLanguage: nil
      ),
      NewDictationRecord(
        id: tieSecondID,
        createdAt: Date(timeIntervalSince1970: 400),
        rawTranscript: "tie second",
        detectedLanguage: nil
      ),
      NewDictationRecord(
        id: tieFirstID,
        createdAt: Date(timeIntervalSince1970: 400),
        rawTranscript: "tie first",
        detectedLanguage: nil
      ),
    ] {
      _ = try await repository.createRecord(record)
    }

    let records = try await repository.records()

    XCTAssertEqual(records.map(\.id), [tieFirstID, tieSecondID, olderID])
  }

  func testDeletingRecordAlsoDeletesOwnedRuns() async throws {
    let repository = try makeRepository()
    let ownerID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
    _ = try await repository.createRecord(
      NewDictationRecord(
        id: ownerID,
        rawTranscript: "raw",
        detectedLanguage: "en"
      )
    )
    _ = try await repository.appendRun(
      NewProcessingRun(
        ownerID: ownerID,
        providerID: "groq",
        modelID: "model",
        configurationHash: "hash",
        outputText: "processed",
        status: .succeeded
      )
    )

    try await repository.deleteRecord(id: ownerID)

    let record = try await repository.record(id: ownerID)
    let runs = try await repository.runs(ownerKind: .dictation, ownerID: ownerID)
    XCTAssertNil(record)
    XCTAssertTrue(runs.isEmpty)
  }

  func testRecordStatusCanMarkPersistedTranscriptCancelled() async throws {
    let repository = try makeRepository()
    let record = try await repository.createRecord(
      NewDictationRecord(rawTranscript: "raw", detectedLanguage: nil)
    )

    let updated = try await repository.updateRecordStatus(
      id: record.id,
      status: .cancelled
    )

    XCTAssertEqual(updated.rawTranscript, record.rawTranscript)
    XCTAssertEqual(updated.status, .cancelled)
  }

  func testPersistentStoreReopensWithRawRecordAndRuns() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpeakNoteM2-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("history.store")
    let ownerID = UUID(uuidString: "00000000-0000-0000-0000-000000000601")!

    try await writePersistentFixture(at: storeURL, ownerID: ownerID)

    let reopenedContainer = try SpeakNoteModelContainer.persistent(at: storeURL)
    let reopened = SwiftDataSessionRepository(
      modelContainer: reopenedContainer
    )
    let record = try await reopened.record(id: ownerID)
    let runs = try await reopened.runs(ownerKind: .dictation, ownerID: ownerID)

    XCTAssertEqual(record?.rawTranscript, "persist me")
    XCTAssertEqual(runs.map(\.outputText), ["persisted output"])
  }

  func testPersistedPayloadHasNoCredentialFields() async throws {
    let repository = try makeRepository()
    let record = try await repository.createRecord(
      NewDictationRecord(rawTranscript: "safe transcript", detectedLanguage: "en")
    )
    let run = try await repository.appendRun(
      NewProcessingRun(
        ownerID: record.id,
        providerID: "groq",
        modelID: "model",
        configurationHash: "configuration-digest",
        outputText: "processed",
        status: .succeeded
      )
    )
    let encoder = JSONEncoder()
    let payload = try XCTUnwrap(
      String(data: encoder.encode([run]), encoding: .utf8)
    ).lowercased()

    XCTAssertFalse(payload.contains("apikey"))
    XCTAssertFalse(payload.contains("authorization"))
    XCTAssertFalse(payload.contains("credential"))
  }

  private func makeRepository() throws -> SwiftDataSessionRepository {
    let container = try SpeakNoteModelContainer.inMemory()
    return SwiftDataSessionRepository(modelContainer: container)
  }

  private func writePersistentFixture(at url: URL, ownerID: UUID) async throws {
    let container = try SpeakNoteModelContainer.persistent(at: url)
    let repository = SwiftDataSessionRepository(modelContainer: container)
    _ = try await repository.createRecord(
      NewDictationRecord(
        id: ownerID,
        rawTranscript: "persist me",
        detectedLanguage: "en"
      )
    )
    _ = try await repository.appendRun(
      NewProcessingRun(
        ownerID: ownerID,
        providerID: "groq",
        modelID: "model",
        configurationHash: "hash",
        outputText: "persisted output",
        status: .succeeded
      )
    )
  }
}

import Foundation
import XCTest

@testable import SpeakNote

@MainActor
final class SettingsRepositoryTests: XCTestCase {
  func testRoundTripsNonSecretSettings() async throws {
    let suiteName = "SpeakNoteTests.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

    let repository = try SettingsRepository(suiteName: suiteName)
    let expected = AppSettings(
      transcriptionProviderID: .appleSpeech,
      transcriptionModelID: "test-model",
      transcriptionFallbackPolicy: .samePrivacyClass,
      localOnly: true,
      defaultVoiceNoteType: .classNotes,
      textProcessingProviderID: .groq,
      textProcessingModelID: "text-model",
      structuredTextModelID: "structured-model",
      recognitionLanguageCode: "en",
      outputLanguageCode: "zh-Hant",
      compressionLevel: .polished,
      dictationHistoryEnabled: false,
      hasAcknowledgedGroqCloudProcessing: true
    )

    try await repository.save(expected)
    let loaded = try await repository.load()

    XCTAssertEqual(loaded, expected)
    let persistedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    XCTAssertNil(persistedDefaults.string(forKey: "apiKey"))
  }

  func testMigratesM1SettingsWithSafeM2Defaults() async throws {
    let suiteName = "SpeakNoteTests.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
    let legacy = try JSONEncoder().encode(
      LegacySettings(
        transcriptionProviderID: .groq,
        transcriptionModelID: "legacy-model"
      )
    )
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.set(legacy, forKey: SettingsRepository.storageKey)
    let repository = try SettingsRepository(suiteName: suiteName)

    let loaded = try await repository.load()

    XCTAssertEqual(loaded.transcriptionProviderID, .groq)
    XCTAssertEqual(loaded.transcriptionModelID, "legacy-model")
    XCTAssertEqual(
      loaded.transcriptionFallbackPolicy,
      .askBeforeCrossingBoundary
    )
    XCTAssertFalse(loaded.localOnly)
    XCTAssertEqual(loaded.defaultVoiceNoteType, .generalNotes)
    XCTAssertEqual(loaded.textProcessingModelID, ProviderDefaults.quickTextModelID)
    XCTAssertEqual(
      loaded.structuredTextModelID,
      ProviderDefaults.structuredTextModelID
    )
    XCTAssertNil(loaded.recognitionLanguageCode)
    XCTAssertNil(loaded.outputLanguageCode)
    XCTAssertEqual(loaded.compressionLevel, .verbatim)
    XCTAssertTrue(loaded.dictationHistoryEnabled)
    XCTAssertFalse(loaded.hasAcknowledgedGroqCloudProcessing)
  }

  func testRejectsCorruptStoredData() async throws {
    let suiteName = "SpeakNoteTests.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

    try XCTUnwrap(UserDefaults(suiteName: suiteName))
      .set(Data("not-json".utf8), forKey: SettingsRepository.storageKey)
    let repository = try SettingsRepository(suiteName: suiteName)

    do {
      _ = try await repository.load()
      XCTFail("Corrupt settings must not be accepted.")
    } catch let error as SettingsRepositoryError {
      XCTAssertEqual(error, .unreadableData)
    }
  }
}

private struct LegacySettings: Codable {
  let transcriptionProviderID: ProviderID
  let transcriptionModelID: String
}

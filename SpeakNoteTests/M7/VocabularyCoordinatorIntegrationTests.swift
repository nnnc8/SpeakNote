import Foundation
import XCTest

@testable import SpeakNote

@MainActor
final class VocabularyCoordinatorIntegrationTests: XCTestCase {
  func testProfileActivationAndTermAndRuleDisablePersist() async throws {
    let repository = SwiftDataVocabularyRepository(
      modelContainer: try SpeakNoteModelContainer.inMemory()
    )
    let settings = M7SettingsRepository()
    let coordinator = VocabularyCoordinator(
      repository: repository,
      settingsRepository: settings
    )
    await coordinator.load()
    coordinator.profileName = "Work"
    coordinator.recognitionLanguageCode = "zh-TW"
    coordinator.outputLanguageCode = "en"
    coordinator.providerIdentifier = ProviderID.appleSpeech.rawValue
    coordinator.defaultNoteTypeIdentifier = NoteType.meetingMinutes.rawValue

    await coordinator.activateSelectedProfile()

    let profileID = try XCTUnwrap(coordinator.selectedProfileID)
    let persistedSettings = try await settings.load()
    XCTAssertNil(coordinator.errorMessage)
    XCTAssertEqual(coordinator.activeProfileID, profileID)
    XCTAssertEqual(persistedSettings.activeProfileID, profileID)
    XCTAssertEqual(persistedSettings.defaultVoiceNoteType, .meetingMinutes)
    XCTAssertEqual(persistedSettings.recognitionLanguageCode, "zh-TW")
    XCTAssertEqual(persistedSettings.outputLanguageCode, "en")
    XCTAssertEqual(persistedSettings.transcriptionProviderID, .appleSpeech)

    coordinator.termDraft = "VoiceMD"
    coordinator.termPriority = 4
    await coordinator.addCustomTerm()
    let term = try XCTUnwrap(coordinator.customTerms.first)
    XCTAssertTrue(term.isEnabled)
    await coordinator.toggleCustomTerm(term)

    coordinator.ruleMatchDraft = "voice md"
    coordinator.ruleReplacementDraft = "VoiceMD"
    coordinator.rulePriority = 7
    await coordinator.addReplacementRule()
    let rule = try XCTUnwrap(coordinator.replacementRules.first)
    XCTAssertTrue(rule.isEnabled)
    await coordinator.toggleReplacementRule(rule)

    let storedTerm = try await repository.customTerm(id: term.id)
    let storedRule = try await repository.replacementRule(id: rule.id)
    XCTAssertEqual(storedTerm?.isEnabled, false)
    XCTAssertEqual(storedRule?.isEnabled, false)
  }

  func testSuggestionsRequireHistoryAndExplicitAcceptOrReject() async throws {
    let repository = SwiftDataVocabularyRepository(
      modelContainer: try SpeakNoteModelContainer.inMemory()
    )
    let settings = M7SettingsRepository()
    let coordinator = VocabularyCoordinator(
      repository: repository,
      settingsRepository: settings
    )
    coordinator.profileName = "Work"
    await coordinator.saveProfile()
    let profileID = try XCTUnwrap(coordinator.selectedProfileID)

    _ = try await repository.appendCorrectionObservations(
      observations(
        profileID: profileID,
        original: "voice md",
        replacement: "VoiceMD"
      ),
      profileID: profileID
    )
    await coordinator.refreshSuggestions()
    let acceptedCandidate = try XCTUnwrap(
      coordinator.suggestions.first { $0.original == "voice md" }
    )
    XCTAssertEqual(acceptedCandidate.status, .pending)
    XCTAssertFalse(coordinator.customTerms.contains { $0.term == "VoiceMD" })

    await coordinator.acceptSuggestion(acceptedCandidate)

    XCTAssertEqual(
      coordinator.suggestions.first { $0.id == acceptedCandidate.id }?.status,
      .accepted
    )
    XCTAssertTrue(coordinator.customTerms.contains { $0.term == "VoiceMD" })

    _ = try await repository.appendCorrectionObservations(
      observations(
        profileID: profileID,
        original: "swift data",
        replacement: "SwiftData"
      ),
      profileID: profileID
    )
    await coordinator.refreshSuggestions()
    let rejectedCandidate = try XCTUnwrap(
      coordinator.suggestions.first { $0.original == "swift data" }
    )
    XCTAssertEqual(rejectedCandidate.status, .pending)
    await coordinator.rejectSuggestion(rejectedCandidate)
    XCTAssertEqual(
      coordinator.suggestions.first { $0.id == rejectedCandidate.id }?.status,
      .rejected
    )
    XCTAssertFalse(coordinator.customTerms.contains { $0.term == "SwiftData" })

    var historyOff = try await settings.load()
    historyOff.dictationHistoryEnabled = false
    try await settings.save(historyOff)
    _ = try await repository.appendCorrectionObservations(
      observations(
        profileID: profileID,
        original: "new candidate",
        replacement: "NewCandidate"
      ),
      profileID: profileID
    )

    await coordinator.refreshSuggestions()

    XCTAssertFalse(coordinator.suggestions.contains { $0.original == "new candidate" })
  }

  private func observations(
    profileID: UUID,
    original: String,
    replacement: String
  ) -> [VocabularyCorrectionObservation] {
    [
      VocabularyCorrectionObservation(
        profileID: profileID,
        original: original,
        replacement: replacement
      ),
      VocabularyCorrectionObservation(
        profileID: profileID,
        original: original,
        replacement: replacement
      ),
    ]
  }
}

private actor M7SettingsRepository: SettingsStoring {
  private var settings: AppSettings

  init(settings: AppSettings = .defaultValue) {
    self.settings = settings
  }

  func load() throws -> AppSettings {
    settings
  }

  func save(_ settings: AppSettings) throws {
    self.settings = settings
  }

  func reset() {
    settings = .defaultValue
  }
}

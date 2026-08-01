import Foundation
import XCTest

@testable import SpeakNote

final class VocabularyPersistenceTests: XCTestCase {
  func testVocabularyStoreReopensWithAllPersistedDomainValues() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpeakNoteM7-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("vocabulary.store")
    let profile = Profile(id: id(1), name: "Work", vocabularyScope: .disabled)
    let term = CustomTerm(
      id: id(11),
      profileID: profile.id,
      term: "VoiceMD",
      isEnabled: false
    )
    let rule = ReplacementRule(
      id: id(21),
      profileID: profile.id,
      match: "voice md",
      replacement: "VoiceMD",
      isEnabled: false
    )
    let storedAudit = audit(ruleID: rule.id, sourceLocation: 0, matched: "voice md")
    let observation = VocabularyCorrectionObservation(
      profileID: profile.id,
      original: "voice md",
      replacement: "VoiceMD"
    )
    let candidate = suggestion(
      profileID: profile.id,
      original: observation.original,
      replacement: observation.replacement,
      count: 2
    )

    try await writePersistentFixture(
      at: storeURL,
      profile: profile,
      term: term,
      rule: rule,
      audit: storedAudit,
      observation: observation,
      candidate: candidate
    )

    let repository = SwiftDataVocabularyRepository(
      modelContainer: try SpeakNoteModelContainer.persistent(at: storeURL)
    )
    let reopenedProfile = try await repository.profile(id: profile.id)
    let reopenedTerms = try await repository.customTerms(profileID: profile.id)
    let reopenedRules = try await repository.replacementRules(profileID: profile.id)
    let reopenedAudits = try await repository.replacementAudits(profileID: profile.id)
    let reopenedObservations = try await repository.correctionObservations(profileID: profile.id)
    let reopenedSuggestions = try await repository.suggestions(profileID: profile.id)

    XCTAssertEqual(reopenedProfile, profile)
    XCTAssertEqual(reopenedTerms, [term])
    XCTAssertEqual(reopenedRules, [rule])
    XCTAssertEqual(reopenedAudits, [storedAudit])
    XCTAssertEqual(reopenedObservations, [observation])
    XCTAssertEqual(reopenedSuggestions.first?.status, .rejected)
  }

  func testProfileScopedCRUDPersistsDisabledStatesAndDeterministicOrder() async throws {
    let repository = try makeRepository()
    let work = Profile(
      id: id(1),
      name: "Work",
      recognitionLanguageCode: "zh-TW",
      outputLanguageCode: "en",
      providerIdentifier: "groq",
      defaultNoteTypeIdentifier: "meeting",
      vocabularyScope: .disabled
    )
    let personal = Profile(id: id(2), name: "Personal")
    _ = try await repository.createProfile(work)
    _ = try await repository.createProfile(personal)

    let lowerPriority = CustomTerm(
      id: id(11),
      profileID: work.id,
      term: "Beta",
      priority: 1
    )
    let disabled = CustomTerm(
      id: id(12),
      profileID: work.id,
      term: "Alpha",
      priority: 9,
      isEnabled: false
    )
    _ = try await repository.createCustomTerm(lowerPriority)
    _ = try await repository.createCustomTerm(disabled)

    let enabledRule = ReplacementRule(
      id: id(21),
      profileID: work.id,
      match: "voice md",
      replacement: "VoiceMD",
      priority: 2
    )
    let disabledRule = ReplacementRule(
      id: id(22),
      profileID: work.id,
      match: "sdk",
      replacement: "SDK",
      priority: 8,
      isEnabled: false,
      isCaseSensitive: true,
      requiresWordBoundaries: false
    )
    _ = try await repository.createReplacementRule(enabledRule)
    _ = try await repository.createReplacementRule(disabledRule)

    let storedProfiles = try await repository.profiles()
    let workTerms = try await repository.customTerms(profileID: work.id)
    let personalTerms = try await repository.customTerms(profileID: personal.id)
    let workRules = try await repository.replacementRules(profileID: work.id)
    let personalRules = try await repository.replacementRules(profileID: personal.id)
    let storedWork = try await repository.profile(id: work.id)
    XCTAssertEqual(storedProfiles.map(\.id), [personal.id, work.id])
    XCTAssertEqual(workTerms, [disabled, lowerPriority])
    XCTAssertEqual(personalTerms, [])
    XCTAssertEqual(workRules, [disabledRule, enabledRule])
    XCTAssertEqual(personalRules, [])
    XCTAssertEqual(storedWork, work)

    var updatedTerm = disabled
    updatedTerm.isEnabled = true
    updatedTerm.priority = 0
    let persistedTerm = try await repository.updateCustomTerm(updatedTerm)
    XCTAssertEqual(persistedTerm, updatedTerm)

    var updatedRule = disabledRule
    updatedRule.isEnabled = true
    let persistedRule = try await repository.updateReplacementRule(updatedRule)
    XCTAssertEqual(persistedRule, updatedRule)

    try await repository.deleteCustomTerm(id: lowerPriority.id)
    try await repository.deleteReplacementRule(id: enabledRule.id)
    let remainingTerms = try await repository.customTerms(profileID: work.id)
    let remainingRules = try await repository.replacementRules(profileID: work.id)
    XCTAssertEqual(remainingTerms, [updatedTerm])
    XCTAssertEqual(remainingRules, [updatedRule])
  }

  func testAuditsAndObservationsAppendInOrderAndStayProfileIsolated() async throws {
    let repository = try makeRepository()
    let work = Profile(id: id(1), name: "Work")
    let personal = Profile(id: id(2), name: "Personal")
    _ = try await repository.createProfile(work)
    _ = try await repository.createProfile(personal)
    let rule = ReplacementRule(
      id: id(21),
      profileID: work.id,
      match: "voice md",
      replacement: "VoiceMD"
    )
    _ = try await repository.createReplacementRule(rule)

    let audits = [
      audit(ruleID: rule.id, sourceLocation: 0, matched: "voice md"),
      audit(ruleID: rule.id, sourceLocation: 12, matched: "voice md"),
    ]
    let observations = [
      VocabularyCorrectionObservation(
        profileID: work.id,
        original: "voice md",
        replacement: "VoiceMD"
      ),
      VocabularyCorrectionObservation(
        profileID: work.id,
        original: "sdk",
        replacement: "SDK"
      ),
    ]

    let appendedAudits = try await repository.appendReplacementAudits(
      audits,
      profileID: work.id
    )
    let appendedObservations = try await repository.appendCorrectionObservations(
      observations,
      profileID: work.id
    )
    let storedAudits = try await repository.replacementAudits(profileID: work.id)
    let storedObservations = try await repository.correctionObservations(profileID: work.id)
    let personalAudits = try await repository.replacementAudits(profileID: personal.id)
    let personalObservations = try await repository.correctionObservations(
      profileID: personal.id
    )
    XCTAssertEqual(appendedAudits, audits)
    XCTAssertEqual(appendedObservations, observations)
    XCTAssertEqual(storedAudits, audits)
    XCTAssertEqual(storedObservations, observations)
    XCTAssertEqual(personalAudits, [])
    XCTAssertEqual(personalObservations, [])
  }

  func testSuggestionUpsertPreservesDecisionsAndAcceptIsExplicitAndAtomic() async throws {
    let repository = try makeRepository()
    let profile = Profile(id: id(1), name: "Work")
    _ = try await repository.createProfile(profile)

    let candidate = suggestion(
      profileID: profile.id,
      original: "voice md",
      replacement: "VoiceMD",
      count: 2
    )
    let initialCandidates = try await repository.upsertSuggestionCandidates(
      [candidate],
      profileID: profile.id
    )
    let initialTerms = try await repository.customTerms(profileID: profile.id)
    XCTAssertEqual(initialCandidates, [candidate])
    XCTAssertEqual(initialTerms, [])

    let inactiveTerm = CustomTerm(
      id: id(31),
      profileID: profile.id,
      term: "VoiceMD",
      priority: 7,
      isEnabled: false
    )
    let accepted = try await repository.acceptSuggestion(id: candidate.id, as: inactiveTerm)
    let acceptedTerms = try await repository.customTerms(profileID: profile.id)
    XCTAssertEqual(accepted.status, .accepted)
    XCTAssertEqual(acceptedTerms, [inactiveTerm])

    let updatedCandidate = suggestion(
      profileID: profile.id,
      original: candidate.original,
      replacement: candidate.replacement,
      count: 5
    )
    let afterUpsert = try await repository.upsertSuggestionCandidates(
      [updatedCandidate],
      profileID: profile.id
    )
    XCTAssertEqual(afterUpsert.first?.occurrenceCount, 5)
    XCTAssertEqual(afterUpsert.first?.status, .accepted)

    let rejectedCandidate = suggestion(
      profileID: profile.id,
      original: "sdk",
      replacement: "SDK",
      count: 3
    )
    _ = try await repository.upsertSuggestionCandidates(
      [rejectedCandidate],
      profileID: profile.id
    )
    let rejected = try await repository.rejectSuggestion(id: rejectedCandidate.id)
    XCTAssertEqual(rejected.status, .rejected)
    let updatedRejected = suggestion(
      profileID: profile.id,
      original: rejectedCandidate.original,
      replacement: rejectedCandidate.replacement,
      count: 9
    )
    let decisions = try await repository.upsertSuggestionCandidates(
      [updatedRejected],
      profileID: profile.id
    )
    XCTAssertEqual(
      decisions.first(where: { $0.id == rejectedCandidate.id })?.status,
      .rejected
    )
    let termsAfterRejection = try await repository.customTerms(profileID: profile.id)
    XCTAssertEqual(termsAfterRejection, [inactiveTerm])

    let pendingCandidate = suggestion(
      profileID: profile.id,
      original: "swift data",
      replacement: "SwiftData",
      count: 2
    )
    _ = try await repository.upsertSuggestionCandidates(
      [pendingCandidate],
      profileID: profile.id
    )
    do {
      _ = try await repository.acceptSuggestion(
        id: pendingCandidate.id,
        as: CustomTerm(
          id: inactiveTerm.id,
          profileID: profile.id,
          term: pendingCandidate.replacement
        )
      )
      XCTFail("Expected duplicate term identifier to reject the atomic acceptance")
    } catch {
      XCTAssertEqual(
        error as? VocabularyRepositoryError,
        .duplicateIdentifier(inactiveTerm.id)
      )
    }
    let finalSuggestions = try await repository.suggestions(profileID: profile.id)
    XCTAssertEqual(
      finalSuggestions.first(where: { $0.id == pendingCandidate.id })?.status,
      .pending
    )
  }

  private func makeRepository() throws -> SwiftDataVocabularyRepository {
    SwiftDataVocabularyRepository(modelContainer: try SpeakNoteModelContainer.inMemory())
  }

  private func writePersistentFixture(
    at url: URL,
    profile: Profile,
    term: CustomTerm,
    rule: ReplacementRule,
    audit: ReplacementAudit,
    observation: VocabularyCorrectionObservation,
    candidate: VocabularySuggestion
  ) async throws {
    let repository = SwiftDataVocabularyRepository(
      modelContainer: try SpeakNoteModelContainer.persistent(at: url)
    )
    _ = try await repository.createProfile(profile)
    _ = try await repository.createCustomTerm(term)
    _ = try await repository.createReplacementRule(rule)
    _ = try await repository.appendReplacementAudits([audit], profileID: profile.id)
    _ = try await repository.appendCorrectionObservations(
      [observation],
      profileID: profile.id
    )
    _ = try await repository.upsertSuggestionCandidates([candidate], profileID: profile.id)
    _ = try await repository.rejectSuggestion(id: candidate.id)
  }

  private func audit(
    ruleID: UUID,
    sourceLocation: Int,
    matched: String
  ) -> ReplacementAudit {
    ReplacementAudit(
      ruleID: ruleID,
      sourceRange: UTF16TextRange(location: sourceLocation, length: matched.utf16.count),
      outputRange: UTF16TextRange(location: sourceLocation, length: 7),
      matchedText: matched,
      replacementText: "VoiceMD",
      rulePriority: 0
    )
  }

  private func suggestion(
    profileID: UUID,
    original: String,
    replacement: String,
    count: Int
  ) -> VocabularySuggestion {
    VocabularySuggestion(
      id: VocabularySuggestion.ID(
        profileID: profileID,
        original: original,
        replacement: replacement
      ),
      profileID: profileID,
      original: original,
      replacement: replacement,
      occurrenceCount: count
    )
  }

  private func id(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
  }
}

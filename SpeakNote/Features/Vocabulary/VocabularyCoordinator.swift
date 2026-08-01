import Combine
import Foundation

@MainActor
final class VocabularyCoordinator: ObservableObject {
  @Published private(set) var profiles: [Profile] = []
  @Published private(set) var customTerms: [CustomTerm] = []
  @Published private(set) var replacementRules: [ReplacementRule] = []
  @Published private(set) var suggestions: [VocabularySuggestion] = []
  @Published private(set) var activeProfileID: UUID?
  @Published var selectedProfileID: UUID?
  @Published private(set) var isCreatingProfile = false
  @Published private(set) var isBusy = false
  @Published var errorMessage: String?

  @Published var profileName = ""
  @Published var recognitionLanguageCode = ""
  @Published var outputLanguageCode = ""
  @Published var providerIdentifier = ""
  @Published var defaultNoteTypeIdentifier = NoteType.generalNotes.rawValue
  @Published var vocabularyEnabled = true

  @Published var termDraft = ""
  @Published var pronunciationDraft = ""
  @Published var termPriority = 0

  @Published var ruleMatchDraft = ""
  @Published var ruleReplacementDraft = ""
  @Published var rulePriority = 0
  @Published var ruleCaseSensitive = false
  @Published var ruleRequiresWordBoundaries = true

  private let repository: any VocabularyStoring
  private let settingsRepository: any SettingsStoring
  private let suggestionGenerator: VocabularySuggestionGenerator
  private let makeID: @Sendable () -> UUID

  init(
    repository: any VocabularyStoring,
    settingsRepository: any SettingsStoring,
    suggestionGenerator: VocabularySuggestionGenerator =
      VocabularySuggestionGenerator(),
    makeID: @escaping @Sendable () -> UUID = UUID.init
  ) {
    self.repository = repository
    self.settingsRepository = settingsRepository
    self.suggestionGenerator = suggestionGenerator
    self.makeID = makeID
  }

  func load() async {
    await perform {
      let settings = try await settingsRepository.load()
      activeProfileID = settings.activeProfileID
      profiles = try await repository.profiles()
      if let activeProfileID,
        profiles.contains(where: { $0.id == activeProfileID })
      {
        await select(activeProfileID)
      } else if let first = profiles.first {
        await select(first.id)
      } else {
        beginNewProfile()
      }
    }
  }

  func beginNewProfile() {
    selectedProfileID = nil
    isCreatingProfile = true
    profileName = ""
    recognitionLanguageCode = ""
    outputLanguageCode = ""
    providerIdentifier = ""
    defaultNoteTypeIdentifier = NoteType.generalNotes.rawValue
    vocabularyEnabled = true
    customTerms = []
    replacementRules = []
    suggestions = []
  }

  func select(_ id: UUID?) async {
    guard let id else {
      beginNewProfile()
      return
    }
    await perform {
      guard let profile = try await repository.profile(id: id) else {
        throw VocabularyCoordinatorError.profileNotFound
      }
      selectedProfileID = id
      isCreatingProfile = false
      populateDraft(from: profile)
      try await reloadProfileContent(profileID: id)
    }
  }

  func saveProfile() async {
    await perform {
      let saved = try await persistProfileDraft()
      selectedProfileID = saved.id
      isCreatingProfile = false
      profiles = try await repository.profiles()
      try await reloadProfileContent(profileID: saved.id)
    }
  }

  func activateSelectedProfile() async {
    await perform {
      let profile = try await persistProfileDraft()
      var settings = try await settingsRepository.load()
      if profile.providerIdentifier == ProviderID.groq.rawValue,
        settings.localOnly
      {
        throw VocabularyCoordinatorError.cloudProfileConflictsWithLocalOnly
      }
      settings.activeProfileID = profile.id
      settings.defaultVoiceNoteType =
        profile.defaultNoteTypeIdentifier.flatMap(NoteType.init(rawValue:))
        ?? .generalNotes
      settings.recognitionLanguageCode = profile.recognitionLanguageCode
      settings.outputLanguageCode = profile.outputLanguageCode
      if let providerIdentifier = profile.providerIdentifier {
        settings.transcriptionProviderID = ProviderID(
          rawValue: providerIdentifier
        )
      }
      try await settingsRepository.save(settings)
      activeProfileID = profile.id
      selectedProfileID = profile.id
      isCreatingProfile = false
      profiles = try await repository.profiles()
      try await reloadProfileContent(profileID: profile.id)
    }
  }

  func deactivateProfile() async {
    await perform {
      var settings = try await settingsRepository.load()
      settings.activeProfileID = nil
      settings.defaultVoiceNoteType = .generalNotes
      try await settingsRepository.save(settings)
      activeProfileID = nil
    }
  }

  func deleteSelectedProfile() async {
    guard let profileID = selectedProfileID else { return }
    await perform {
      try await repository.deleteProfile(id: profileID)
      if activeProfileID == profileID {
        var settings = try await settingsRepository.load()
        settings.activeProfileID = nil
        settings.defaultVoiceNoteType = .generalNotes
        try await settingsRepository.save(settings)
        activeProfileID = nil
      }
      profiles = try await repository.profiles()
      if let first = profiles.first {
        await select(first.id)
      } else {
        beginNewProfile()
      }
    }
  }

  func addCustomTerm() async {
    guard let profileID = selectedProfileID else { return }
    await perform {
      let value = try normalizedRequired(termDraft)
      _ = try await repository.createCustomTerm(
        CustomTerm(
          id: makeID(),
          profileID: profileID,
          term: value,
          pronunciationHint: normalizedOptional(pronunciationDraft),
          priority: termPriority
        )
      )
      termDraft = ""
      pronunciationDraft = ""
      termPriority = 0
      customTerms = try await repository.customTerms(profileID: profileID)
    }
  }

  func toggleCustomTerm(_ term: CustomTerm) async {
    await perform {
      var updated = term
      updated.isEnabled.toggle()
      _ = try await repository.updateCustomTerm(updated)
      customTerms = try await repository.customTerms(
        profileID: term.profileID
      )
    }
  }

  func deleteCustomTerm(_ term: CustomTerm) async {
    await perform {
      try await repository.deleteCustomTerm(id: term.id)
      customTerms = try await repository.customTerms(
        profileID: term.profileID
      )
    }
  }

  func addReplacementRule() async {
    guard let profileID = selectedProfileID else { return }
    await perform {
      _ = try await repository.createReplacementRule(
        ReplacementRule(
          id: makeID(),
          profileID: profileID,
          match: normalizedRequired(ruleMatchDraft),
          replacement: normalizedRequired(ruleReplacementDraft),
          priority: rulePriority,
          isCaseSensitive: ruleCaseSensitive,
          requiresWordBoundaries: ruleRequiresWordBoundaries
        )
      )
      ruleMatchDraft = ""
      ruleReplacementDraft = ""
      rulePriority = 0
      ruleCaseSensitive = false
      ruleRequiresWordBoundaries = true
      replacementRules = try await repository.replacementRules(
        profileID: profileID
      )
    }
  }

  func toggleReplacementRule(_ rule: ReplacementRule) async {
    await perform {
      var updated = rule
      updated.isEnabled.toggle()
      _ = try await repository.updateReplacementRule(updated)
      replacementRules = try await repository.replacementRules(
        profileID: rule.profileID
      )
    }
  }

  func deleteReplacementRule(_ rule: ReplacementRule) async {
    await perform {
      try await repository.deleteReplacementRule(id: rule.id)
      replacementRules = try await repository.replacementRules(
        profileID: rule.profileID
      )
    }
  }

  func refreshSuggestions() async {
    guard let profileID = selectedProfileID else { return }
    await perform {
      guard let profile = try await repository.profile(id: profileID) else {
        throw VocabularyCoordinatorError.profileNotFound
      }
      let settings = try await settingsRepository.load()
      guard settings.dictationHistoryEnabled else {
        suggestions = try await repository.suggestions(profileID: profileID)
        return
      }
      let observations = try await repository.correctionObservations(
        profileID: profileID
      )
      let candidates = suggestionGenerator.generate(
        for: profile,
        historyEnabled: true,
        observations: observations
      )
      suggestions = try await repository.upsertSuggestionCandidates(
        candidates,
        profileID: profileID
      )
    }
  }

  func acceptSuggestion(_ suggestion: VocabularySuggestion) async {
    await perform {
      _ = try await repository.acceptSuggestion(
        id: suggestion.id,
        as: CustomTerm(
          id: makeID(),
          profileID: suggestion.profileID,
          term: suggestion.replacement,
          pronunciationHint: suggestion.original,
          priority: suggestion.occurrenceCount
        )
      )
      try await reloadProfileContent(profileID: suggestion.profileID)
    }
  }

  func rejectSuggestion(_ suggestion: VocabularySuggestion) async {
    await perform {
      _ = try await repository.rejectSuggestion(id: suggestion.id)
      suggestions = try await repository.suggestions(
        profileID: suggestion.profileID
      )
    }
  }

  var selectedProfileIsActive: Bool {
    selectedProfileID != nil && selectedProfileID == activeProfileID
  }

  private func persistProfileDraft() async throws -> Profile {
    let profile = Profile(
      id: selectedProfileID ?? makeID(),
      name: try normalizedRequired(profileName),
      recognitionLanguageCode: normalizedOptional(recognitionLanguageCode),
      outputLanguageCode: normalizedOptional(outputLanguageCode),
      providerIdentifier: normalizedOptional(providerIdentifier),
      defaultNoteTypeIdentifier: normalizedOptional(defaultNoteTypeIdentifier),
      vocabularyScope: vocabularyEnabled ? .profileOnly : .disabled
    )
    if selectedProfileID == nil {
      return try await repository.createProfile(profile)
    }
    return try await repository.updateProfile(profile)
  }

  private func populateDraft(from profile: Profile) {
    profileName = profile.name
    recognitionLanguageCode = profile.recognitionLanguageCode ?? ""
    outputLanguageCode = profile.outputLanguageCode ?? ""
    providerIdentifier = profile.providerIdentifier ?? ""
    defaultNoteTypeIdentifier =
      profile.defaultNoteTypeIdentifier ?? NoteType.generalNotes.rawValue
    vocabularyEnabled = profile.vocabularyScope == .profileOnly
  }

  private func reloadProfileContent(profileID: UUID) async throws {
    async let loadedTerms = repository.customTerms(profileID: profileID)
    async let loadedRules = repository.replacementRules(profileID: profileID)
    async let loadedSuggestions = repository.suggestions(profileID: profileID)
    customTerms = try await loadedTerms
    replacementRules = try await loadedRules
    suggestions = try await loadedSuggestions
  }

  private func perform(_ operation: () async throws -> Void) async {
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      try await operation()
    } catch let error as VocabularyCoordinatorError {
      errorMessage = error.errorDescription
    } catch {
      errorMessage = String(localized: "Vocabulary changes could not be saved.")
    }
  }

  private func normalizedRequired(_ value: String) throws -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      throw VocabularyCoordinatorError.requiredValueMissing
    }
    return normalized
  }

  private func normalizedOptional(_ value: String) -> String? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }
}

private enum VocabularyCoordinatorError: Error, LocalizedError {
  case requiredValueMissing
  case profileNotFound
  case cloudProfileConflictsWithLocalOnly

  var errorDescription: String? {
    switch self {
    case .requiredValueMissing:
      String(localized: "Complete the required vocabulary field.")
    case .profileNotFound:
      String(localized: "The selected profile no longer exists.")
    case .cloudProfileConflictsWithLocalOnly:
      String(
        localized:
          "Turn off local-only transcription before activating a Groq profile."
      )
    }
  }
}

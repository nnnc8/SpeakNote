import Foundation
import SwiftData

enum VocabularyRepositoryError: Error, Equatable, Sendable {
  case duplicateIdentifier(UUID)
  case profileNotFound(UUID)
  case customTermNotFound(UUID)
  case replacementRuleNotFound(UUID)
  case suggestionNotFound(VocabularySuggestion.ID)
  case profileMismatch
  case invalidProfile
  case invalidCustomTerm
  case invalidReplacementRule
  case invalidAudit
  case invalidObservation
  case invalidSuggestion
  case invalidStoredValue
}

protocol VocabularyStoring: Actor {
  func createProfile(_ profile: Profile) throws -> Profile
  func profile(id: UUID) throws -> Profile?
  func profiles() throws -> [Profile]
  func updateProfile(_ profile: Profile) throws -> Profile
  func deleteProfile(id: UUID) throws

  func createCustomTerm(_ term: CustomTerm) throws -> CustomTerm
  func customTerm(id: UUID) throws -> CustomTerm?
  func customTerms(profileID: UUID) throws -> [CustomTerm]
  func updateCustomTerm(_ term: CustomTerm) throws -> CustomTerm
  func deleteCustomTerm(id: UUID) throws

  func createReplacementRule(_ rule: ReplacementRule) throws -> ReplacementRule
  func replacementRule(id: UUID) throws -> ReplacementRule?
  func replacementRules(profileID: UUID) throws -> [ReplacementRule]
  func updateReplacementRule(_ rule: ReplacementRule) throws -> ReplacementRule
  func deleteReplacementRule(id: UUID) throws

  func appendReplacementAudits(
    _ audits: [ReplacementAudit],
    profileID: UUID
  ) throws -> [ReplacementAudit]
  func replacementAudits(profileID: UUID) throws -> [ReplacementAudit]
  func appendCorrectionObservations(
    _ observations: [VocabularyCorrectionObservation],
    profileID: UUID
  ) throws -> [VocabularyCorrectionObservation]
  func correctionObservations(profileID: UUID) throws
    -> [VocabularyCorrectionObservation]

  func upsertSuggestionCandidates(
    _ suggestions: [VocabularySuggestion],
    profileID: UUID
  ) throws -> [VocabularySuggestion]
  func suggestions(profileID: UUID) throws -> [VocabularySuggestion]
  func acceptSuggestion(
    id: VocabularySuggestion.ID,
    as customTerm: CustomTerm
  ) throws -> VocabularySuggestion
  func rejectSuggestion(id: VocabularySuggestion.ID) throws -> VocabularySuggestion
}

@ModelActor
actor SwiftDataVocabularyRepository: VocabularyStoring {
  func createProfile(_ profile: Profile) throws -> Profile {
    guard isValid(profile) else { throw VocabularyRepositoryError.invalidProfile }
    guard try profileModel(id: profile.id) == nil else {
      throw VocabularyRepositoryError.duplicateIdentifier(profile.id)
    }

    let model = VocabularyProfileModel(
      id: profile.id,
      name: profile.name,
      recognitionLanguageCode: profile.recognitionLanguageCode,
      outputLanguageCode: profile.outputLanguageCode,
      providerIdentifier: profile.providerIdentifier,
      defaultNoteTypeIdentifier: profile.defaultNoteTypeIdentifier,
      vocabularyScopeRawValue: profile.vocabularyScope.rawValue
    )
    modelContext.insert(model)
    try modelContext.save()
    return try dto(from: model)
  }

  func profile(id: UUID) throws -> Profile? {
    try profileModel(id: id).map(dto(from:))
  }

  func profiles() throws -> [Profile] {
    try modelContext.fetch(FetchDescriptor<VocabularyProfileModel>())
      .map(dto(from:))
      .sorted {
        if $0.name != $1.name { return $0.name < $1.name }
        return $0.id.uuidString < $1.id.uuidString
      }
  }

  func updateProfile(_ profile: Profile) throws -> Profile {
    guard isValid(profile) else { throw VocabularyRepositoryError.invalidProfile }
    guard let model = try profileModel(id: profile.id) else {
      throw VocabularyRepositoryError.profileNotFound(profile.id)
    }

    model.name = profile.name
    model.recognitionLanguageCode = profile.recognitionLanguageCode
    model.outputLanguageCode = profile.outputLanguageCode
    model.providerIdentifier = profile.providerIdentifier
    model.defaultNoteTypeIdentifier = profile.defaultNoteTypeIdentifier
    model.vocabularyScopeRawValue = profile.vocabularyScope.rawValue
    try modelContext.save()
    return try dto(from: model)
  }

  func deleteProfile(id: UUID) throws {
    guard let profile = try profileModel(id: id) else { return }
    for term in try termModels(profileID: id) { modelContext.delete(term) }
    for rule in try ruleModels(profileID: id) { modelContext.delete(rule) }
    for audit in try auditModels(profileID: id) { modelContext.delete(audit) }
    for observation in try observationModels(profileID: id) {
      modelContext.delete(observation)
    }
    for suggestion in try suggestionModels(profileID: id) {
      modelContext.delete(suggestion)
    }
    modelContext.delete(profile)
    try modelContext.save()
  }

  func createCustomTerm(_ term: CustomTerm) throws -> CustomTerm {
    guard isValid(term) else { throw VocabularyRepositoryError.invalidCustomTerm }
    try requireProfile(term.profileID)
    guard try termModel(id: term.id) == nil else {
      throw VocabularyRepositoryError.duplicateIdentifier(term.id)
    }

    let model = CustomTermModel(
      id: term.id,
      profileID: term.profileID,
      term: term.term,
      pronunciationHint: term.pronunciationHint,
      priority: term.priority,
      isEnabled: term.isEnabled
    )
    modelContext.insert(model)
    try modelContext.save()
    return dto(from: model)
  }

  func customTerm(id: UUID) throws -> CustomTerm? {
    try termModel(id: id).map(dto(from:))
  }

  func customTerms(profileID: UUID) throws -> [CustomTerm] {
    try requireProfile(profileID)
    return try termModels(profileID: profileID)
      .map(dto(from:))
      .sorted {
        if $0.priority != $1.priority { return $0.priority > $1.priority }
        if $0.term != $1.term { return $0.term < $1.term }
        return $0.id.uuidString < $1.id.uuidString
      }
  }

  func updateCustomTerm(_ term: CustomTerm) throws -> CustomTerm {
    guard isValid(term) else { throw VocabularyRepositoryError.invalidCustomTerm }
    guard let model = try termModel(id: term.id) else {
      throw VocabularyRepositoryError.customTermNotFound(term.id)
    }
    guard model.profileID == term.profileID else {
      throw VocabularyRepositoryError.profileMismatch
    }

    model.term = term.term
    model.pronunciationHint = term.pronunciationHint
    model.priority = term.priority
    model.isEnabled = term.isEnabled
    try modelContext.save()
    return dto(from: model)
  }

  func deleteCustomTerm(id: UUID) throws {
    guard let model = try termModel(id: id) else { return }
    modelContext.delete(model)
    try modelContext.save()
  }

  func createReplacementRule(_ rule: ReplacementRule) throws -> ReplacementRule {
    guard isValid(rule) else { throw VocabularyRepositoryError.invalidReplacementRule }
    try requireProfile(rule.profileID)
    guard try ruleModel(id: rule.id) == nil else {
      throw VocabularyRepositoryError.duplicateIdentifier(rule.id)
    }

    let model = ReplacementRuleModel(
      id: rule.id,
      profileID: rule.profileID,
      match: rule.match,
      replacement: rule.replacement,
      priority: rule.priority,
      isEnabled: rule.isEnabled,
      isCaseSensitive: rule.isCaseSensitive,
      requiresWordBoundaries: rule.requiresWordBoundaries
    )
    modelContext.insert(model)
    try modelContext.save()
    return dto(from: model)
  }

  func replacementRule(id: UUID) throws -> ReplacementRule? {
    try ruleModel(id: id).map(dto(from:))
  }

  func replacementRules(profileID: UUID) throws -> [ReplacementRule] {
    try requireProfile(profileID)
    return try ruleModels(profileID: profileID)
      .map(dto(from:))
      .sorted {
        if $0.priority != $1.priority { return $0.priority > $1.priority }
        if $0.match != $1.match { return $0.match < $1.match }
        return $0.id.uuidString < $1.id.uuidString
      }
  }

  func updateReplacementRule(_ rule: ReplacementRule) throws -> ReplacementRule {
    guard isValid(rule) else { throw VocabularyRepositoryError.invalidReplacementRule }
    guard let model = try ruleModel(id: rule.id) else {
      throw VocabularyRepositoryError.replacementRuleNotFound(rule.id)
    }
    guard model.profileID == rule.profileID else {
      throw VocabularyRepositoryError.profileMismatch
    }

    model.match = rule.match
    model.replacement = rule.replacement
    model.priority = rule.priority
    model.isEnabled = rule.isEnabled
    model.isCaseSensitive = rule.isCaseSensitive
    model.requiresWordBoundaries = rule.requiresWordBoundaries
    try modelContext.save()
    return dto(from: model)
  }

  func deleteReplacementRule(id: UUID) throws {
    guard let model = try ruleModel(id: id) else { return }
    modelContext.delete(model)
    try modelContext.save()
  }

  func appendReplacementAudits(
    _ audits: [ReplacementAudit],
    profileID: UUID
  ) throws -> [ReplacementAudit] {
    try requireProfile(profileID)
    guard try audits.allSatisfy({ try isValid($0, profileID: profileID) }) else {
      throw VocabularyRepositoryError.invalidAudit
    }

    let start = (try auditModels(profileID: profileID).map(\.sequence).max() ?? -1) + 1
    for (offset, audit) in audits.enumerated() {
      modelContext.insert(
        ReplacementAuditModel(
          id: UUID(),
          profileID: profileID,
          sequence: start + Int64(offset),
          ruleID: audit.ruleID,
          sourceLocation: audit.sourceRange.location,
          sourceLength: audit.sourceRange.length,
          outputLocation: audit.outputRange.location,
          outputLength: audit.outputRange.length,
          matchedText: audit.matchedText,
          replacementText: audit.replacementText,
          rulePriority: audit.rulePriority
        )
      )
    }
    if !audits.isEmpty { try modelContext.save() }
    return audits
  }

  func replacementAudits(profileID: UUID) throws -> [ReplacementAudit] {
    try requireProfile(profileID)
    return try auditModels(profileID: profileID)
      .sorted {
        if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
        return $0.id.uuidString < $1.id.uuidString
      }
      .map(dto(from:))
  }

  func appendCorrectionObservations(
    _ observations: [VocabularyCorrectionObservation],
    profileID: UUID
  ) throws -> [VocabularyCorrectionObservation] {
    try requireProfile(profileID)
    guard observations.allSatisfy({ isValid($0, profileID: profileID) }) else {
      throw VocabularyRepositoryError.invalidObservation
    }

    let start = (try observationModels(profileID: profileID).map(\.sequence).max() ?? -1) + 1
    for (offset, observation) in observations.enumerated() {
      modelContext.insert(
        VocabularyCorrectionObservationModel(
          id: UUID(),
          profileID: profileID,
          sequence: start + Int64(offset),
          original: observation.original,
          replacement: observation.replacement
        )
      )
    }
    if !observations.isEmpty { try modelContext.save() }
    return observations
  }

  func correctionObservations(profileID: UUID) throws
    -> [VocabularyCorrectionObservation]
  {
    try requireProfile(profileID)
    return try observationModels(profileID: profileID)
      .sorted {
        if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
        return $0.id.uuidString < $1.id.uuidString
      }
      .map(dto(from:))
  }

  func upsertSuggestionCandidates(
    _ suggestions: [VocabularySuggestion],
    profileID: UUID
  ) throws -> [VocabularySuggestion] {
    try requireProfile(profileID)
    guard
      Set(suggestions.map(\.id)).count == suggestions.count,
      suggestions.allSatisfy({ isValidCandidate($0, profileID: profileID) })
    else {
      throw VocabularyRepositoryError.invalidSuggestion
    }

    for suggestion in suggestions.sorted(by: suggestionComesFirst) {
      let identity = suggestionIdentity(suggestion.id)
      if let model = try suggestionModel(identity: identity) {
        model.occurrenceCount = suggestion.occurrenceCount
      } else {
        modelContext.insert(
          VocabularySuggestionModel(
            id: UUID(),
            identity: identity,
            profileID: profileID,
            original: suggestion.original,
            replacement: suggestion.replacement,
            occurrenceCount: suggestion.occurrenceCount,
            statusRawValue: VocabularySuggestionStatus.pending.rawValue
          )
        )
      }
    }
    if !suggestions.isEmpty { try modelContext.save() }
    return try self.suggestions(profileID: profileID)
  }

  func suggestions(profileID: UUID) throws -> [VocabularySuggestion] {
    try requireProfile(profileID)
    return try suggestionModels(profileID: profileID)
      .map(dto(from:))
      .sorted(by: suggestionComesFirst)
  }

  func acceptSuggestion(
    id: VocabularySuggestion.ID,
    as customTerm: CustomTerm
  ) throws -> VocabularySuggestion {
    guard customTerm.profileID == id.profileID, customTerm.term == id.replacement else {
      throw VocabularyRepositoryError.profileMismatch
    }
    guard isValid(customTerm) else { throw VocabularyRepositoryError.invalidCustomTerm }
    guard try termModel(id: customTerm.id) == nil else {
      throw VocabularyRepositoryError.duplicateIdentifier(customTerm.id)
    }
    guard let suggestion = try suggestionModel(identity: suggestionIdentity(id)) else {
      throw VocabularyRepositoryError.suggestionNotFound(id)
    }
    let currentStatus = try suggestionStatus(from: suggestion)
    guard currentStatus == .pending else {
      throw VocabularySuggestionTransitionError.alreadyDecided(currentStatus)
    }

    suggestion.statusRawValue = VocabularySuggestionStatus.accepted.rawValue
    modelContext.insert(
      CustomTermModel(
        id: customTerm.id,
        profileID: customTerm.profileID,
        term: customTerm.term,
        pronunciationHint: customTerm.pronunciationHint,
        priority: customTerm.priority,
        isEnabled: customTerm.isEnabled
      )
    )
    do {
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
    return try dto(from: suggestion)
  }

  func rejectSuggestion(id: VocabularySuggestion.ID) throws -> VocabularySuggestion {
    guard let suggestion = try suggestionModel(identity: suggestionIdentity(id)) else {
      throw VocabularyRepositoryError.suggestionNotFound(id)
    }
    let currentStatus = try suggestionStatus(from: suggestion)
    guard currentStatus == .pending else {
      throw VocabularySuggestionTransitionError.alreadyDecided(currentStatus)
    }

    suggestion.statusRawValue = VocabularySuggestionStatus.rejected.rawValue
    try modelContext.save()
    return try dto(from: suggestion)
  }

  private func requireProfile(_ id: UUID) throws {
    guard try profileModel(id: id) != nil else {
      throw VocabularyRepositoryError.profileNotFound(id)
    }
  }

  private func profileModel(id: UUID) throws -> VocabularyProfileModel? {
    var descriptor = FetchDescriptor<VocabularyProfileModel>(
      predicate: #Predicate { $0.id == id }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func termModel(id: UUID) throws -> CustomTermModel? {
    var descriptor = FetchDescriptor<CustomTermModel>(
      predicate: #Predicate { $0.id == id }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func termModels(profileID: UUID) throws -> [CustomTermModel] {
    try modelContext.fetch(
      FetchDescriptor<CustomTermModel>(
        predicate: #Predicate { $0.profileID == profileID }
      )
    )
  }

  private func ruleModel(id: UUID) throws -> ReplacementRuleModel? {
    var descriptor = FetchDescriptor<ReplacementRuleModel>(
      predicate: #Predicate { $0.id == id }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func ruleModels(profileID: UUID) throws -> [ReplacementRuleModel] {
    try modelContext.fetch(
      FetchDescriptor<ReplacementRuleModel>(
        predicate: #Predicate { $0.profileID == profileID }
      )
    )
  }

  private func auditModels(profileID: UUID) throws -> [ReplacementAuditModel] {
    try modelContext.fetch(
      FetchDescriptor<ReplacementAuditModel>(
        predicate: #Predicate { $0.profileID == profileID }
      )
    )
  }

  private func observationModels(
    profileID: UUID
  ) throws -> [VocabularyCorrectionObservationModel] {
    try modelContext.fetch(
      FetchDescriptor<VocabularyCorrectionObservationModel>(
        predicate: #Predicate { $0.profileID == profileID }
      )
    )
  }

  private func suggestionModels(profileID: UUID) throws -> [VocabularySuggestionModel] {
    try modelContext.fetch(
      FetchDescriptor<VocabularySuggestionModel>(
        predicate: #Predicate { $0.profileID == profileID }
      )
    )
  }

  private func suggestionModel(identity: String) throws -> VocabularySuggestionModel? {
    var descriptor = FetchDescriptor<VocabularySuggestionModel>(
      predicate: #Predicate { $0.identity == identity }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func isValid(_ profile: Profile) -> Bool {
    !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func isValid(_ term: CustomTerm) -> Bool {
    !term.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func isValid(_ rule: ReplacementRule) -> Bool {
    !rule.match.isEmpty
  }

  private func isValid(_ audit: ReplacementAudit, profileID: UUID) throws -> Bool {
    guard
      audit.sourceRange.location >= 0,
      audit.sourceRange.length > 0,
      audit.outputRange.location >= 0,
      audit.outputRange.length >= 0,
      !audit.matchedText.isEmpty,
      let rule = try ruleModel(id: audit.ruleID)
    else {
      return false
    }
    return rule.profileID == profileID
  }

  private func isValid(
    _ observation: VocabularyCorrectionObservation,
    profileID: UUID
  ) -> Bool {
    observation.profileID == profileID
      && !observation.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !observation.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && observation.original != observation.replacement
  }

  private func isValidCandidate(
    _ suggestion: VocabularySuggestion,
    profileID: UUID
  ) -> Bool {
    suggestion.profileID == profileID
      && suggestion.id.profileID == profileID
      && suggestion.id.original == suggestion.original
      && suggestion.id.replacement == suggestion.replacement
      && !suggestion.original.isEmpty
      && !suggestion.replacement.isEmpty
      && suggestion.original != suggestion.replacement
      && suggestion.occurrenceCount > 0
      && suggestion.status == .pending
  }

  private func dto(from model: VocabularyProfileModel) throws -> Profile {
    guard let scope = VocabularyScope(rawValue: model.vocabularyScopeRawValue) else {
      throw VocabularyRepositoryError.invalidStoredValue
    }
    return Profile(
      id: model.id,
      name: model.name,
      recognitionLanguageCode: model.recognitionLanguageCode,
      outputLanguageCode: model.outputLanguageCode,
      providerIdentifier: model.providerIdentifier,
      defaultNoteTypeIdentifier: model.defaultNoteTypeIdentifier,
      vocabularyScope: scope
    )
  }

  private func dto(from model: CustomTermModel) -> CustomTerm {
    CustomTerm(
      id: model.id,
      profileID: model.profileID,
      term: model.term,
      pronunciationHint: model.pronunciationHint,
      priority: model.priority,
      isEnabled: model.isEnabled
    )
  }

  private func dto(from model: ReplacementRuleModel) -> ReplacementRule {
    ReplacementRule(
      id: model.id,
      profileID: model.profileID,
      match: model.match,
      replacement: model.replacement,
      priority: model.priority,
      isEnabled: model.isEnabled,
      isCaseSensitive: model.isCaseSensitive,
      requiresWordBoundaries: model.requiresWordBoundaries
    )
  }

  private func dto(from model: ReplacementAuditModel) -> ReplacementAudit {
    ReplacementAudit(
      ruleID: model.ruleID,
      sourceRange: UTF16TextRange(
        location: model.sourceLocation,
        length: model.sourceLength
      ),
      outputRange: UTF16TextRange(
        location: model.outputLocation,
        length: model.outputLength
      ),
      matchedText: model.matchedText,
      replacementText: model.replacementText,
      rulePriority: model.rulePriority
    )
  }

  private func dto(
    from model: VocabularyCorrectionObservationModel
  ) -> VocabularyCorrectionObservation {
    VocabularyCorrectionObservation(
      profileID: model.profileID,
      original: model.original,
      replacement: model.replacement
    )
  }

  private func dto(from model: VocabularySuggestionModel) throws -> VocabularySuggestion {
    VocabularySuggestion(
      id: VocabularySuggestion.ID(
        profileID: model.profileID,
        original: model.original,
        replacement: model.replacement
      ),
      profileID: model.profileID,
      original: model.original,
      replacement: model.replacement,
      occurrenceCount: model.occurrenceCount,
      status: try suggestionStatus(from: model)
    )
  }

  private func suggestionStatus(
    from model: VocabularySuggestionModel
  ) throws -> VocabularySuggestionStatus {
    guard let status = VocabularySuggestionStatus(rawValue: model.statusRawValue) else {
      throw VocabularyRepositoryError.invalidStoredValue
    }
    return status
  }

  private func suggestionIdentity(_ id: VocabularySuggestion.ID) -> String {
    let original = Data(id.original.utf8).base64EncodedString()
    let replacement = Data(id.replacement.utf8).base64EncodedString()
    return "\(id.profileID.uuidString)|\(original)|\(replacement)"
  }

  private func suggestionComesFirst(
    _ lhs: VocabularySuggestion,
    _ rhs: VocabularySuggestion
  ) -> Bool {
    if lhs.occurrenceCount != rhs.occurrenceCount {
      return lhs.occurrenceCount > rhs.occurrenceCount
    }
    if lhs.original != rhs.original { return lhs.original < rhs.original }
    return lhs.replacement < rhs.replacement
  }
}

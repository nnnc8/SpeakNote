import Foundation
import SwiftData

@Model
final class VocabularyProfileModel {
  @Attribute(.unique) var id: UUID
  var name: String
  var recognitionLanguageCode: String?
  var outputLanguageCode: String?
  var providerIdentifier: String?
  var defaultNoteTypeIdentifier: String?
  var vocabularyScopeRawValue: String

  init(
    id: UUID,
    name: String,
    recognitionLanguageCode: String?,
    outputLanguageCode: String?,
    providerIdentifier: String?,
    defaultNoteTypeIdentifier: String?,
    vocabularyScopeRawValue: String
  ) {
    self.id = id
    self.name = name
    self.recognitionLanguageCode = recognitionLanguageCode
    self.outputLanguageCode = outputLanguageCode
    self.providerIdentifier = providerIdentifier
    self.defaultNoteTypeIdentifier = defaultNoteTypeIdentifier
    self.vocabularyScopeRawValue = vocabularyScopeRawValue
  }
}

@Model
final class CustomTermModel {
  @Attribute(.unique) var id: UUID
  var profileID: UUID
  var term: String
  var pronunciationHint: String?
  var priority: Int
  var isEnabled: Bool

  init(
    id: UUID,
    profileID: UUID,
    term: String,
    pronunciationHint: String?,
    priority: Int,
    isEnabled: Bool
  ) {
    self.id = id
    self.profileID = profileID
    self.term = term
    self.pronunciationHint = pronunciationHint
    self.priority = priority
    self.isEnabled = isEnabled
  }
}

@Model
final class ReplacementRuleModel {
  @Attribute(.unique) var id: UUID
  var profileID: UUID
  var match: String
  var replacement: String
  var priority: Int
  var isEnabled: Bool
  var isCaseSensitive: Bool
  var requiresWordBoundaries: Bool

  init(
    id: UUID,
    profileID: UUID,
    match: String,
    replacement: String,
    priority: Int,
    isEnabled: Bool,
    isCaseSensitive: Bool,
    requiresWordBoundaries: Bool
  ) {
    self.id = id
    self.profileID = profileID
    self.match = match
    self.replacement = replacement
    self.priority = priority
    self.isEnabled = isEnabled
    self.isCaseSensitive = isCaseSensitive
    self.requiresWordBoundaries = requiresWordBoundaries
  }
}

@Model
final class ReplacementAuditModel {
  @Attribute(.unique) var id: UUID
  var profileID: UUID
  var sequence: Int64
  var ruleID: UUID
  var sourceLocation: Int
  var sourceLength: Int
  var outputLocation: Int
  var outputLength: Int
  var matchedText: String
  var replacementText: String
  var rulePriority: Int

  init(
    id: UUID,
    profileID: UUID,
    sequence: Int64,
    ruleID: UUID,
    sourceLocation: Int,
    sourceLength: Int,
    outputLocation: Int,
    outputLength: Int,
    matchedText: String,
    replacementText: String,
    rulePriority: Int
  ) {
    self.id = id
    self.profileID = profileID
    self.sequence = sequence
    self.ruleID = ruleID
    self.sourceLocation = sourceLocation
    self.sourceLength = sourceLength
    self.outputLocation = outputLocation
    self.outputLength = outputLength
    self.matchedText = matchedText
    self.replacementText = replacementText
    self.rulePriority = rulePriority
  }
}

@Model
final class VocabularyCorrectionObservationModel {
  @Attribute(.unique) var id: UUID
  var profileID: UUID
  var sequence: Int64
  var original: String
  var replacement: String

  init(
    id: UUID,
    profileID: UUID,
    sequence: Int64,
    original: String,
    replacement: String
  ) {
    self.id = id
    self.profileID = profileID
    self.sequence = sequence
    self.original = original
    self.replacement = replacement
  }
}

@Model
final class VocabularySuggestionModel {
  @Attribute(.unique) var id: UUID
  @Attribute(.unique) var identity: String
  var profileID: UUID
  var original: String
  var replacement: String
  var occurrenceCount: Int
  var statusRawValue: String

  init(
    id: UUID,
    identity: String,
    profileID: UUID,
    original: String,
    replacement: String,
    occurrenceCount: Int,
    statusRawValue: String
  ) {
    self.id = id
    self.identity = identity
    self.profileID = profileID
    self.original = original
    self.replacement = replacement
    self.occurrenceCount = occurrenceCount
    self.statusRawValue = statusRawValue
  }
}

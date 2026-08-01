import Foundation

enum VocabularyScope: String, Codable, Equatable, Hashable, Sendable {
  case profileOnly
  case disabled
}

struct Profile: Codable, Equatable, Hashable, Identifiable, Sendable {
  let id: UUID
  var name: String
  var recognitionLanguageCode: String?
  var outputLanguageCode: String?
  var providerIdentifier: String?
  var defaultNoteTypeIdentifier: String?
  var vocabularyScope: VocabularyScope

  init(
    id: UUID,
    name: String,
    recognitionLanguageCode: String? = nil,
    outputLanguageCode: String? = nil,
    providerIdentifier: String? = nil,
    defaultNoteTypeIdentifier: String? = nil,
    vocabularyScope: VocabularyScope = .profileOnly
  ) {
    self.id = id
    self.name = name
    self.recognitionLanguageCode = recognitionLanguageCode
    self.outputLanguageCode = outputLanguageCode
    self.providerIdentifier = providerIdentifier
    self.defaultNoteTypeIdentifier = defaultNoteTypeIdentifier
    self.vocabularyScope = vocabularyScope
  }
}

struct CustomTerm: Codable, Equatable, Hashable, Identifiable, Sendable {
  let id: UUID
  let profileID: UUID
  var term: String
  var pronunciationHint: String?
  var priority: Int
  var isEnabled: Bool

  init(
    id: UUID,
    profileID: UUID,
    term: String,
    pronunciationHint: String? = nil,
    priority: Int = 0,
    isEnabled: Bool = true
  ) {
    self.id = id
    self.profileID = profileID
    self.term = term
    self.pronunciationHint = pronunciationHint
    self.priority = priority
    self.isEnabled = isEnabled
  }
}

struct CustomTermSelection: Equatable, Sendable {
  let terms: [CustomTerm]
  let promptFragment: String
  let conservativeTokenCount: Int
  let wasTruncated: Bool
}

struct ReplacementRule: Codable, Equatable, Hashable, Identifiable, Sendable {
  let id: UUID
  let profileID: UUID
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
    priority: Int = 0,
    isEnabled: Bool = true,
    isCaseSensitive: Bool = false,
    requiresWordBoundaries: Bool = true
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

enum ReplacementConflictPolicy: String, Codable, Equatable, Sendable {
  case highestPriorityThenLongestMatch
}

struct UTF16TextRange: Codable, Equatable, Hashable, Sendable {
  let location: Int
  let length: Int
}

struct ReplacementAudit: Codable, Equatable, Sendable {
  let ruleID: UUID
  let sourceRange: UTF16TextRange
  let outputRange: UTF16TextRange
  let matchedText: String
  let replacementText: String
  let rulePriority: Int
}

struct ReplacementResult: Equatable, Sendable {
  let text: String
  let auditTrail: [ReplacementAudit]
  let conflictPolicy: ReplacementConflictPolicy
}

struct VocabularyCorrectionObservation: Codable, Equatable, Hashable, Sendable {
  let profileID: UUID
  let original: String
  let replacement: String
}

enum VocabularySuggestionStatus: String, Codable, Equatable, Hashable, Sendable {
  case pending
  case accepted
  case rejected
}

struct VocabularySuggestion: Codable, Equatable, Hashable, Identifiable, Sendable {
  struct ID: Codable, Equatable, Hashable, Sendable {
    let profileID: UUID
    let original: String
    let replacement: String
  }

  let id: ID
  let profileID: UUID
  let original: String
  let replacement: String
  let occurrenceCount: Int
  let status: VocabularySuggestionStatus

  init(
    id: ID,
    profileID: UUID,
    original: String,
    replacement: String,
    occurrenceCount: Int,
    status: VocabularySuggestionStatus = .pending
  ) {
    self.id = id
    self.profileID = profileID
    self.original = original
    self.replacement = replacement
    self.occurrenceCount = occurrenceCount
    self.status = status
  }
}

enum VocabularySuggestionTransitionError: Error, Equatable, Sendable {
  case alreadyDecided(VocabularySuggestionStatus)
}

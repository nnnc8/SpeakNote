import Foundation

struct VocabularySuggestionGenerator: Sendable {
  func generate(
    for profile: Profile,
    historyEnabled: Bool,
    observations: [VocabularyCorrectionObservation],
    minimumOccurrences: Int = 2
  ) -> [VocabularySuggestion] {
    guard historyEnabled, profile.vocabularyScope == .profileOnly else { return [] }

    var counts: [CandidateKey: Int] = [:]
    for observation in observations where observation.profileID == profile.id {
      let original = normalizedWhitespace(observation.original)
      let replacement = normalizedWhitespace(observation.replacement)
      guard !original.isEmpty, !replacement.isEmpty, original != replacement else { continue }
      counts[CandidateKey(original: original, replacement: replacement), default: 0] += 1
    }

    let threshold = max(1, minimumOccurrences)
    return
      counts
      .filter { $0.value >= threshold }
      .map { key, count in
        VocabularySuggestion(
          id: VocabularySuggestion.ID(
            profileID: profile.id,
            original: key.original,
            replacement: key.replacement
          ),
          profileID: profile.id,
          original: key.original,
          replacement: key.replacement,
          occurrenceCount: count
        )
      }
      .sorted { lhs, rhs in
        if lhs.occurrenceCount != rhs.occurrenceCount {
          return lhs.occurrenceCount > rhs.occurrenceCount
        }
        if lhs.original != rhs.original {
          return lhs.original < rhs.original
        }
        return lhs.replacement < rhs.replacement
      }
  }

  private func normalizedWhitespace(_ value: String) -> String {
    value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  private struct CandidateKey: Hashable {
    let original: String
    let replacement: String
  }
}

enum VocabularySuggestionTransition {
  static func accept(_ suggestion: VocabularySuggestion) throws -> VocabularySuggestion {
    try transition(suggestion, to: .accepted)
  }

  static func reject(_ suggestion: VocabularySuggestion) throws -> VocabularySuggestion {
    try transition(suggestion, to: .rejected)
  }

  private static func transition(
    _ suggestion: VocabularySuggestion,
    to status: VocabularySuggestionStatus
  ) throws -> VocabularySuggestion {
    guard suggestion.status == .pending else {
      throw VocabularySuggestionTransitionError.alreadyDecided(suggestion.status)
    }
    return VocabularySuggestion(
      id: suggestion.id,
      profileID: suggestion.profileID,
      original: suggestion.original,
      replacement: suggestion.replacement,
      occurrenceCount: suggestion.occurrenceCount,
      status: status
    )
  }
}
